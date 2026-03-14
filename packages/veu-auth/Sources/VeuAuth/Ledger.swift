// Ledger.swift — Veu Protocol: Local Artifact Ledger (SQLite)
//
// Bootstraps the LEDGER.sql schema and provides CRUD operations for the
// device-local artifact ledger.  Uses the SQLite3 C API available natively
// on Apple platforms (no external dependency).
//
// Zero-Aware design: the ledger knows *that* an artifact exists; it never
// knows *what* it is.  All content metadata is stored in an encrypted blob.

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Device-local SQLite ledger for Circle and artifact management.
///
/// The `Ledger` class manages a single SQLite database file that stores:
/// - Circle membership records (encrypted names, keys stored separately in Secure Enclave)
/// - Artifact records (CID, encrypted metadata, sync state, burn timers)
/// - Administrative metadata (schema version, device ID)
///
/// # Production Note
/// In production the database file itself should be stored in the app's
/// encrypted container (iOS Data Protection) with the key wrapped by the
/// Secure Enclave.  For the POC, a plain-file SQLite database is used.
public final class Ledger {

    // MARK: - Properties

    private var db: OpaquePointer?

    /// The file path of the opened database (`:memory:` for in-memory).
    public let path: String

    // MARK: - Lifecycle

    /// Open (or create) a ledger database at the given path.
    ///
    /// - Parameter path: File path for the SQLite database.
    ///                   Pass `":memory:"` for an in-memory database (useful for tests).
    /// - Throws: `VeuAuthError.ledgerError` if the database cannot be opened.
    public init(path: String = ":memory:") throws {
        self.path = path
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &dbPointer, flags, nil)
        guard rc == SQLITE_OK, let openedDB = dbPointer else {
            let msg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPointer)
            throw VeuAuthError.ledgerError("Failed to open database: \(msg)")
        }
        self.db = openedDB
        try bootstrap()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema Bootstrap

    /// Execute the LEDGER.sql schema to create all tables and indexes,
    /// then run any needed migrations for existing databases.
    private func bootstrap() throws {
        let schema = Ledger.schemaSQL
        try execute(schema)
        try migrateArtifactTypes()
    }

    /// Migrate existing databases whose artifacts CHECK constraint is missing
    /// the 'reaction' and 'comment' types added in v3.
    private func migrateArtifactTypes() throws {
        // Check the CREATE TABLE sql to see if 'reaction' is already allowed.
        let tableSql: [String] = try query(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='artifacts'"
        ) { stmt in
            String(cString: sqlite3_column_text(stmt, 0))
        }
        guard let createSql = tableSql.first else { return }
        if createSql.contains("'reaction'") { return }

        let migration = """
            PRAGMA foreign_keys = OFF;

            CREATE TABLE artifacts_new (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                cid              TEXT    NOT NULL UNIQUE,
                circle_id        TEXT    NOT NULL REFERENCES circles(circle_id) ON DELETE CASCADE,
                artifact_type    TEXT    NOT NULL CHECK (artifact_type IN ('post', 'file', 'message', 'burn_notice', 'reaction', 'comment')),
                encrypted_meta   BLOB    NOT NULL,
                sender_id        TEXT,
                target_recipients TEXT,
                wrapped_keys     TEXT,
                sync_state       TEXT    NOT NULL DEFAULT 'pending'
                                         CHECK (sync_state IN ('pending', 'synced', 'purged')),
                created_at       INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                synced_at        INTEGER,
                purged_at        INTEGER,
                burn_after       INTEGER
            );

            INSERT INTO artifacts_new SELECT * FROM artifacts;
            DROP TABLE artifacts;
            ALTER TABLE artifacts_new RENAME TO artifacts;

            CREATE INDEX IF NOT EXISTS idx_artifacts_circle_created
                ON artifacts (circle_id, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_artifacts_sync_state
                ON artifacts (sync_state) WHERE sync_state != 'purged';
            CREATE INDEX IF NOT EXISTS idx_artifacts_burn_after
                ON artifacts (burn_after) WHERE burn_after IS NOT NULL AND sync_state != 'purged';
            CREATE INDEX IF NOT EXISTS idx_artifacts_created_at
                ON artifacts (created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_artifacts_circle_active
                ON artifacts (circle_id, created_at DESC) WHERE sync_state != 'purged';

            PRAGMA foreign_keys = ON;
            """
        try execute(migration)
    }

    // MARK: - Circle Operations

    /// Insert a new Circle into the ledger.
    ///
    /// - Parameters:
    ///   - circleID: Opaque Circle identifier (UUID or fingerprint).
    ///   - encryptedName: AES-256-GCM encrypted display name blob.
    public func insertCircle(circleID: String, encryptedName: Data) throws {
        let sql = "INSERT INTO circles (circle_id, encrypted_name) VALUES (?, ?)"
        try executeWithBindings(sql) { stmt in
            sqlite3_bind_text(stmt, 1, (circleID as NSString).utf8String, -1, nil)
            sqlite3_bind_blob(stmt, 2, (encryptedName as NSData).bytes, Int32(encryptedName.count), nil)
        }
    }

    /// Fetch all Circle IDs from the ledger.
    ///
    /// - Returns: An array of Circle identifier strings.
    public func listCircles() throws -> [String] {
        let sql = "SELECT circle_id FROM circles ORDER BY joined_at DESC"
        return try query(sql) { stmt in
            String(cString: sqlite3_column_text(stmt, 0))
        }
    }

    /// Delete a Circle and all its artifacts (CASCADE).
    ///
    /// - Parameter circleID: The Circle to remove.
    public func deleteCircle(circleID: String) throws {
        let sql = "DELETE FROM circles WHERE circle_id = ?"
        try executeWithBindings(sql) { stmt in
            sqlite3_bind_text(stmt, 1, (circleID as NSString).utf8String, -1, nil)
        }
    }

    // MARK: - Circle Member Operations

    /// Insert a member into a circle.
    public func insertCircleMember(
        circleID: String,
        deviceID: String,
        publicKeyHex: String,
        callsign: String
    ) throws {
        let sql = """
            INSERT OR REPLACE INTO circle_members (circle_id, device_id, public_key_hex, callsign)
            VALUES (?, ?, ?, ?)
            """
        try executeWithBindings(sql) { stmt in
            sqlite3_bind_text(stmt, 1, (circleID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (publicKeyHex as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (callsign as NSString).utf8String, -1, nil)
        }
    }

    /// List all members of a circle.
    public func listCircleMembers(circleID: String) throws -> [(deviceID: String, publicKeyHex: String, callsign: String)] {
        let sql = "SELECT device_id, public_key_hex, callsign FROM circle_members WHERE circle_id = ? ORDER BY joined_at"
        var stmtPtr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmtPtr, nil) == SQLITE_OK, let stmt = stmtPtr else {
            throw VeuAuthError.ledgerError("Prepare failed: \(lastErrorMessage)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (circleID as NSString).utf8String, -1, nil)

        var results: [(deviceID: String, publicKeyHex: String, callsign: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let deviceID = String(cString: sqlite3_column_text(stmt, 0))
            let publicKeyHex = String(cString: sqlite3_column_text(stmt, 1))
            let callsign = String(cString: sqlite3_column_text(stmt, 2))
            results.append((deviceID: deviceID, publicKeyHex: publicKeyHex, callsign: callsign))
        }
        return results
    }

    /// Remove a member from a circle.
    public func removeCircleMember(circleID: String, deviceID: String) throws {
        let sql = "DELETE FROM circle_members WHERE circle_id = ? AND device_id = ?"
        try executeWithBindings(sql) { stmt in
            sqlite3_bind_text(stmt, 1, (circleID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceID as NSString).utf8String, -1, nil)
        }
    }

    // MARK: - Artifact Operations

    /// Insert a new artifact record.
    ///
    /// - Parameters:
    ///   - cid: IPFS CIDv1 (base32) content identifier.
    ///   - circleID: The Circle this artifact belongs to.
    ///   - artifactType: One of `post`, `file`, `message`, `burn_notice`.
    ///   - encryptedMeta: AES-256-GCM encrypted metadata blob.
    ///   - senderID: Optional device ID of the sender.
    ///   - targetRecipients: Optional JSON array of target device IDs (nil = everyone).
    ///   - wrappedKeys: Optional JSON dict of recipient device ID → base64 wrapped key.
    ///   - burnAfter: Optional Unix timestamp for auto-burn scheduling.
    /// - Returns: The SQLite rowid of the inserted artifact.
    @discardableResult
    public func insertArtifact(
        cid: String,
        circleID: String,
        artifactType: String,
        encryptedMeta: Data,
        senderID: String? = nil,
        targetRecipients: String? = nil,
        wrappedKeys: String? = nil,
        burnAfter: Int? = nil
    ) throws -> Int64 {
        let sql = """
            INSERT INTO artifacts (cid, circle_id, artifact_type, encrypted_meta, sender_id, target_recipients, wrapped_keys, burn_after)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        var stmtPtr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmtPtr, nil) == SQLITE_OK, let stmt = stmtPtr else {
            throw VeuAuthError.ledgerError("Prepare failed: \(lastErrorMessage)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (cid as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (circleID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (artifactType as NSString).utf8String, -1, nil)
        sqlite3_bind_blob(stmt, 4, (encryptedMeta as NSData).bytes, Int32(encryptedMeta.count), nil)
        
        if let senderID = senderID {
            sqlite3_bind_text(stmt, 5, (senderID as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        
        if let targetRecipients = targetRecipients {
            sqlite3_bind_text(stmt, 6, (targetRecipients as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        
        if let wrappedKeys = wrappedKeys {
            sqlite3_bind_text(stmt, 7, (wrappedKeys as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        
        if let burnAfter = burnAfter {
            sqlite3_bind_int64(stmt, 8, Int64(burnAfter))
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VeuAuthError.ledgerError("Insert failed: \(lastErrorMessage)")
        }

        return sqlite3_last_insert_rowid(db)
    }

    /// Fetch all non-purged artifact CIDs for a Circle.
    ///
    /// - Parameter circleID: The Circle to query.
    /// - Returns: An array of CID strings.
    public func listArtifacts(circleID: String) throws -> [String] {
        let sql = "SELECT cid FROM artifacts WHERE circle_id = ? AND sync_state != 'purged' ORDER BY created_at DESC"
        var stmtPtr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmtPtr, nil) == SQLITE_OK, let stmt = stmtPtr else {
            throw VeuAuthError.ledgerError("Prepare failed: \(lastErrorMessage)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (circleID as NSString).utf8String, -1, nil)

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return results
    }

    /// Purge an artifact (Burn): set sync_state to 'purged' and record the purge time.
    ///
    /// - Parameter cid: The CID of the artifact to purge.
    public func purgeArtifact(cid: String) throws {
        let sql = "UPDATE artifacts SET sync_state = 'purged', purged_at = strftime('%s', 'now') WHERE cid = ?"
        try executeWithBindings(sql) { stmt in
            sqlite3_bind_text(stmt, 1, (cid as NSString).utf8String, -1, nil)
        }
    }

    /// Mark an artifact as synced.
    ///
    /// - Parameter cid: The CID of the artifact to mark.
    public func markSynced(cid: String) throws {
        let sql = "UPDATE artifacts SET sync_state = 'synced', synced_at = strftime('%s', 'now') WHERE cid = ?"
        try executeWithBindings(sql) { stmt in
            sqlite3_bind_text(stmt, 1, (cid as NSString).utf8String, -1, nil)
        }
    }

    /// Fetch artifacts whose burn_after time has passed (candidates for auto-purge).
    ///
    /// - Returns: An array of CID strings ready to be purged.
    public func expiredArtifacts() throws -> [String] {
        let sql = """
            SELECT cid FROM artifacts
            WHERE burn_after IS NOT NULL
              AND burn_after <= strftime('%s', 'now')
              AND sync_state != 'purged'
            """
        return try query(sql) { stmt in
            String(cString: sqlite3_column_text(stmt, 0))
        }
    }

    /// Artifact details returned from the ledger.
    public struct ArtifactDetails {
        public let cid: String
        public let artifactType: String
        public let encryptedMeta: Data
        public let senderID: String?
        public let targetRecipients: [String]?
        public let wrappedKeys: [String: String]?
        public let burnAfter: Int?
        public let createdAt: Int?
    }

    /// Fetch full artifact details for sync.
    ///
    /// - Parameter circleID: The Circle to query.
    /// - Returns: Array of ArtifactDetails.
    public func listArtifactDetails(circleID: String) throws -> [ArtifactDetails] {
        let sql = """
            SELECT cid, artifact_type, encrypted_meta, sender_id, target_recipients, wrapped_keys, burn_after, created_at
            FROM artifacts
            WHERE circle_id = ? AND sync_state != 'purged'
            ORDER BY created_at DESC
            """
        var stmtPtr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmtPtr, nil) == SQLITE_OK, let stmt = stmtPtr else {
            throw VeuAuthError.ledgerError("Prepare failed: \(lastErrorMessage)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (circleID as NSString).utf8String, -1, nil)

        var results: [ArtifactDetails] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = String(cString: sqlite3_column_text(stmt, 0))
            let artifactType = String(cString: sqlite3_column_text(stmt, 1))
            let metaBytes = sqlite3_column_blob(stmt, 2)
            let metaLen = sqlite3_column_bytes(stmt, 2)
            let meta = metaBytes.map { Data(bytes: $0, count: Int(metaLen)) } ?? Data()
            
            let senderID: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
            
            var targetRecipients: [String]?
            if sqlite3_column_type(stmt, 4) != SQLITE_NULL,
               let text = sqlite3_column_text(stmt, 4),
               let data = String(cString: text).data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                targetRecipients = decoded
            }
            
            var wrappedKeys: [String: String]?
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL,
               let text = sqlite3_column_text(stmt, 5),
               let data = String(cString: text).data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                wrappedKeys = decoded
            }
            
            let burnAfter: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 6))
            let createdAt: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 7))
            
            results.append(ArtifactDetails(
                cid: cid,
                artifactType: artifactType,
                encryptedMeta: meta,
                senderID: senderID,
                targetRecipients: targetRecipients,
                wrappedKeys: wrappedKeys,
                burnAfter: burnAfter,
                createdAt: createdAt
            ))
        }
        return results
    }

    // MARK: - Metadata

    /// Get the current schema version.
    ///
    /// - Returns: The schema version integer, or `nil` if no metadata row exists.
    public func schemaVersion() throws -> Int? {
        let sql = "SELECT schema_version FROM ledger_meta WHERE id = 1"
        let results: [Int] = try query(sql) { stmt in
            Int(sqlite3_column_int(stmt, 0))
        }
        return results.first
    }

    /// Initialize the metadata singleton row.
    ///
    /// - Parameter deviceID: The random device UUID (generated at first launch).
    public func initializeMeta(deviceID: String) throws {
        let sql = """
            INSERT OR IGNORE INTO ledger_meta (id, schema_version, device_id, created_at)
            VALUES (1, 1, ?, strftime('%s', 'now'))
            """
        try executeWithBindings(sql) { stmt in
            sqlite3_bind_text(stmt, 1, (deviceID as NSString).utf8String, -1, nil)
        }
    }

    // MARK: - Private SQL Helpers

    private func execute(_ sql: String) throws {
        var errorMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        if rc != SQLITE_OK {
            let msg = errorMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMsg)
            throw VeuAuthError.ledgerError(msg)
        }
    }

    private func executeWithBindings(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmtPtr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmtPtr, nil) == SQLITE_OK, let stmt = stmtPtr else {
            throw VeuAuthError.ledgerError("Prepare failed: \(lastErrorMessage)")
        }
        defer { sqlite3_finalize(stmt) }

        bind(stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VeuAuthError.ledgerError("Execute failed: \(lastErrorMessage)")
        }
    }

    private func query<T>(_ sql: String, map: (OpaquePointer) -> T) throws -> [T] {
        var stmtPtr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmtPtr, nil) == SQLITE_OK, let stmt = stmtPtr else {
            throw VeuAuthError.ledgerError("Prepare failed: \(lastErrorMessage)")
        }
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(map(stmt))
        }
        return results
    }

    private var lastErrorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    // MARK: - Schema SQL

    /// The full LEDGER.sql schema, embedded as a Swift string.
    /// v2 adds sender_id, target_recipients, wrapped_keys to artifacts, and circle_members table.
    static let schemaSQL = """
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS ledger_meta (
            id             INTEGER PRIMARY KEY CHECK (id = 1),
            schema_version INTEGER NOT NULL DEFAULT 2,
            device_id      TEXT    NOT NULL,
            created_at     INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS circles (
            circle_id      TEXT    PRIMARY KEY,
            encrypted_name BLOB    NOT NULL,
            joined_at      INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            last_active_at INTEGER
        );

        CREATE TABLE IF NOT EXISTS circle_members (
            circle_id      TEXT    NOT NULL REFERENCES circles(circle_id) ON DELETE CASCADE,
            device_id      TEXT    NOT NULL,
            public_key_hex TEXT    NOT NULL,
            callsign       TEXT    NOT NULL,
            joined_at      INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            PRIMARY KEY (circle_id, device_id)
        );

        CREATE TABLE IF NOT EXISTS artifacts (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            cid              TEXT    NOT NULL UNIQUE,
            circle_id        TEXT    NOT NULL REFERENCES circles(circle_id) ON DELETE CASCADE,
            artifact_type    TEXT    NOT NULL CHECK (artifact_type IN ('post', 'file', 'message', 'burn_notice', 'reaction', 'comment')),
            encrypted_meta   BLOB    NOT NULL,
            sender_id        TEXT,
            target_recipients TEXT,
            wrapped_keys     TEXT,
            sync_state       TEXT    NOT NULL DEFAULT 'pending'
                                     CHECK (sync_state IN ('pending', 'synced', 'purged')),
            created_at       INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            synced_at        INTEGER,
            purged_at        INTEGER,
            burn_after       INTEGER
        );

        CREATE INDEX IF NOT EXISTS idx_artifacts_circle_created
            ON artifacts (circle_id, created_at DESC);

        CREATE INDEX IF NOT EXISTS idx_artifacts_sync_state
            ON artifacts (sync_state)
            WHERE sync_state != 'purged';

        CREATE INDEX IF NOT EXISTS idx_artifacts_burn_after
            ON artifacts (burn_after)
            WHERE burn_after IS NOT NULL AND sync_state != 'purged';

        CREATE INDEX IF NOT EXISTS idx_artifacts_created_at
            ON artifacts (created_at DESC);

        CREATE INDEX IF NOT EXISTS idx_artifacts_circle_active
            ON artifacts (circle_id, created_at DESC)
            WHERE sync_state != 'purged';

        CREATE INDEX IF NOT EXISTS idx_circle_members_circle
            ON circle_members (circle_id);
        """
}
