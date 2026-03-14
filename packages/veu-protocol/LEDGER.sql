-- =============================================================================
-- LEDGER.sql — Veu Protocol: Local Artifact Ledger
-- =============================================================================
-- SQLite schema for the Local Artifact Ledger.  This database is created and
-- maintained entirely on the user's device.  No table, column, or row in this
-- schema ever contains plaintext content.  All user-generated material is
-- referenced only by its IPFS content-addressed hash (CID); anything that could
-- be considered metadata (mime type hint, size) is stored in an encrypted blob
-- so that even physical access to the device file does not reveal what the user
-- has sent or received.
--
-- Zero-Aware design principle:
--   "The ledger knows *that* an artifact exists; it never knows *what* it is."
-- =============================================================================

PRAGMA journal_mode = WAL;   -- Write-Ahead Logging: safer concurrent reads
PRAGMA foreign_keys = ON;    -- Enforce referential integrity at the SQLite layer


-- =============================================================================
-- Table: ledger_meta
-- =============================================================================
-- Stores exactly one row of administrative metadata.  This table exists so that
-- migration scripts can inspect the schema version before applying changes, and
-- so the sync layer can identify which device produced this ledger file without
-- exposing user-identifiable information (the device_id is a random UUID
-- generated at first launch, not linked to any hardware identifier in the
-- plaintext).
--
-- Zero-Aware note: device_id is opaque; it is never transmitted to a server and
-- is used only for local conflict resolution when a user operates multiple
-- devices within the same Circle.
-- =============================================================================
CREATE TABLE IF NOT EXISTS ledger_meta (
    id             INTEGER PRIMARY KEY CHECK (id = 1),  -- singleton row guard
    schema_version INTEGER NOT NULL DEFAULT 1,          -- incremented on migrations
    device_id      TEXT    NOT NULL,                    -- random UUID, generated at first launch
    created_at     INTEGER NOT NULL                     -- Unix epoch (seconds) of first ledger creation
);


-- =============================================================================
-- Table: artifacts
-- =============================================================================
-- Central record of every artifact the local user has sent or received within
-- their Circles.  An "artifact" is any discrete unit of Veu content: a post,
-- file, message, or burn notice.
--
-- Zero-Aware notes:
--   • `cid`            — IPFS CIDv1 (base32).  Content-addressed, so it is
--                        deterministic from the *ciphertext*, not the plaintext.
--                        Knowing the CID gives an adversary nothing beyond the
--                        knowledge that some encrypted blob exists.
--   • `artifact_type`  — A categorical label that does NOT describe the
--                        content; it describes the protocol action (e.g.
--                        'burn_notice' tells the sync layer to schedule deletion,
--                        not what was burned).
--   • `encrypted_meta` — A single opaque AES-256-GCM blob that contains JSON
--                        with size, mime-type hint, and thumbnail seed.  The
--                        decryption key is the Circle Key; without it this
--                        column is indistinguishable from random bytes.
--   • `sync_state`     — Describes the local lifecycle of the artifact in the
--                        Ghost Network, never revealed to any server.
-- =============================================================================
CREATE TABLE IF NOT EXISTS artifacts (
    -- Primary key: local auto-increment rowid; NOT the CID, so that the schema
    -- does not leak ordering or count information to the file system layer.
    id             INTEGER PRIMARY KEY AUTOINCREMENT,

    -- IPFS CIDv1 (base32-encoded).  Globally unique, content-addressed.
    -- The CID is derived from the *ciphertext* blob, not the plaintext, so
    -- possession of this value gives an observer no information about the
    -- artifact's contents.
    cid            TEXT    NOT NULL UNIQUE,

    -- The Circle this artifact belongs to.  Circles are referenced by their
    -- own opaque identifier (see the circles table).
    circle_id      TEXT    NOT NULL REFERENCES circles(circle_id) ON DELETE CASCADE,

    -- Protocol-level type of the artifact.  Permissible values:
    --   'post'         — a Glazed media post within a Circle
    --   'file'         — a shared file attachment
    --   'message'      — a direct or Circle text message (encrypted payload)
    --   'burn_notice'  — a tombstone record indicating a scheduled purge
    -- This column is used by the sync layer for routing, not for content analysis.
    artifact_type  TEXT    NOT NULL CHECK (artifact_type IN ('post', 'file', 'message', 'burn_notice', 'reaction', 'comment')),

    -- AES-256-GCM encrypted blob containing a JSON object with fields:
    --   { "size_bytes": <int>, "mime_hint": "<string>", "glaze_seed": "<hex>" }
    -- The decryption key is the Circle's symmetric key stored in the Secure
    -- Enclave.  On disk this is indistinguishable from random bytes.
    encrypted_meta BLOB    NOT NULL,

    -- Ghost Network sync lifecycle state.  Permissible values:
    --   'pending'  — created locally, not yet confirmed by any peer
    --   'synced'   — at least one peer has acknowledged receipt
    --   'purged'   — burn/purge has been executed; ciphertext deleted, tombstone kept
    sync_state     TEXT    NOT NULL DEFAULT 'pending'
                           CHECK (sync_state IN ('pending', 'synced', 'purged')),

    -- Unix epoch (seconds) when this record was first written to the ledger.
    created_at     INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),

    -- Unix epoch (seconds) when the sync_state last transitioned to 'synced'.
    -- NULL until the artifact has been acknowledged by at least one peer.
    synced_at      INTEGER,

    -- Unix epoch (seconds) when the sync_state transitioned to 'purged'.
    -- NULL until the Burn/Purge procedure has been executed.
    purged_at      INTEGER,

    -- Unix epoch (seconds) after which this artifact MUST be purged by the
    -- local Burn/Purge scheduler.  NULL means no scheduled expiry (the artifact
    -- persists until the user manually deletes it or a burn_notice is received).
    -- The scheduler checks this column on every app foreground event and on a
    -- background task timer.
    burn_after     INTEGER
);


-- =============================================================================
-- Table: circles
-- =============================================================================
-- Minimal local registry of the Circles the device participates in.  The full
-- Circle membership graph lives in the Ghost Network layer; this table only
-- stores the local device's participation records.
--
-- Zero-Aware note: `circle_id` is an opaque random identifier.  The Circle's
-- human-readable name (if any) is stored in `encrypted_name` so that the
-- database file does not leak social graph information.
-- =============================================================================
CREATE TABLE IF NOT EXISTS circles (
    circle_id      TEXT    PRIMARY KEY,   -- random UUID or public-key fingerprint
    encrypted_name BLOB    NOT NULL,      -- AES-256-GCM encrypted display name
    joined_at      INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    last_active_at INTEGER
);


-- =============================================================================
-- Indexes
-- =============================================================================

-- Circle-based lookup: fetch all artifacts for a given Circle ordered by
-- creation time (the most common query pattern for timeline rendering).
CREATE INDEX IF NOT EXISTS idx_artifacts_circle_created
    ON artifacts (circle_id, created_at DESC);

-- Sync-state lookup: the Ghost Network sync layer needs to find all 'pending'
-- artifacts quickly to determine what still needs to be propagated.
CREATE INDEX IF NOT EXISTS idx_artifacts_sync_state
    ON artifacts (sync_state)
    WHERE sync_state != 'purged';  -- partial index: excludes already-purged rows

-- Burn/Purge scheduler lookup: find artifacts whose burn_after time has passed.
-- This index is used by the background scheduler that runs on app foreground
-- and on a periodic background task.
CREATE INDEX IF NOT EXISTS idx_artifacts_burn_after
    ON artifacts (burn_after)
    WHERE burn_after IS NOT NULL AND sync_state != 'purged';

-- Time-based query across all circles (e.g. "recent activity" feed).
CREATE INDEX IF NOT EXISTS idx_artifacts_created_at
    ON artifacts (created_at DESC);

-- Per-Circle lookup of non-purged artifacts only (the default UI view never
-- shows purged tombstones).
CREATE INDEX IF NOT EXISTS idx_artifacts_circle_active
    ON artifacts (circle_id, created_at DESC)
    WHERE sync_state != 'purged';
