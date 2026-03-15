package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// Artifact represents an encrypted artifact stored by the relay.
type Artifact struct {
	CID       string `json:"cid"`
	Payload   string `json:"payload"`
	Timestamp int64  `json:"timestamp"`
}

// PushToken represents a registered APNs push token.
type PushToken struct {
	TopicHash string
	DeviceID  string
	Token     string
}

// Invite represents a single-use remote handshake invitation.
type Invite struct {
	Token     string `json:"token"`
	Payload   string `json:"payload"`
	TopicHash string `json:"topic_hash"`
	CreatedAt int64  `json:"created_at"`
	ExpiresAt int64  `json:"expires_at"`
}

// Store provides SQLite-backed persistence for encrypted artifacts and push tokens.
type Store struct {
	db *sql.DB
}

// New opens (or creates) the SQLite database at path and runs migrations.
func New(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", path+"?_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping db: %w", err)
	}

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}

	slog.Info("store initialized", "path", path)
	return s, nil
}

func (s *Store) migrate() error {
	// Phase 1: create base tables (columns may evolve — keep the original schema).
	baseSchema := []string{
		`CREATE TABLE IF NOT EXISTS artifacts (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			cid TEXT NOT NULL UNIQUE,
			topic_hash TEXT NOT NULL,
			payload BLOB NOT NULL,
			created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
		)`,
		`CREATE INDEX IF NOT EXISTS idx_artifacts_topic_created ON artifacts (topic_hash, created_at)`,
		`CREATE TABLE IF NOT EXISTS push_tokens (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			topic_hash TEXT NOT NULL,
			device_id TEXT NOT NULL,
			token TEXT NOT NULL,
			updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
			UNIQUE(topic_hash, device_id)
		)`,
	}

	for _, m := range baseSchema {
		if _, err := s.db.Exec(m); err != nil {
			return fmt.Errorf("exec migration: %w", err)
		}
	}

	// Phase 2: add columns that may not exist yet (ALTER TABLE is a no-op if column present).
	s.db.Exec(`ALTER TABLE artifacts ADD COLUMN burn_after INTEGER`)

	// Phase 3: indexes that depend on columns added in phase 2.
	s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_artifacts_burn_after ON artifacts (burn_after) WHERE burn_after IS NOT NULL`)

	// Phase 4: invites table for single-use remote handshake invitations.
	s.db.Exec(`CREATE TABLE IF NOT EXISTS invites (
		token TEXT PRIMARY KEY,
		payload TEXT NOT NULL,
		topic_hash TEXT NOT NULL,
		created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
		expires_at INTEGER NOT NULL
	)`)
	s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_invites_expires ON invites (expires_at)`)

	return nil
}

// InsertArtifact stores an encrypted artifact. Returns false if the CID already exists (duplicate).
func (s *Store) InsertArtifact(ctx context.Context, cid, topicHash, payload string, burnAfter *int64) (bool, error) {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO artifacts (cid, topic_hash, payload, burn_after) VALUES (?, ?, ?, ?)`,
		cid, topicHash, payload, burnAfter,
	)
	if err != nil {
		// Handle UNIQUE constraint violation — artifact already stored.
		if isUniqueViolation(err) {
			slog.Debug("duplicate artifact skipped", "cid", cid)
			return false, nil
		}
		return false, fmt.Errorf("insert artifact: %w", err)
	}
	return true, nil
}

// DeleteArtifact removes an artifact by CID. Used for burn notices.
func (s *Store) DeleteArtifact(ctx context.Context, cid string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM artifacts WHERE cid = ?`, cid)
	if err != nil {
		return fmt.Errorf("delete artifact: %w", err)
	}
	return nil
}

// PruneExpired deletes all artifacts whose burn_after timestamp has passed.
// Returns the number of rows deleted.
func (s *Store) PruneExpired(ctx context.Context) (int64, error) {
	now := time.Now().Unix()
	result, err := s.db.ExecContext(ctx,
		`DELETE FROM artifacts WHERE burn_after IS NOT NULL AND burn_after <= ?`, now)
	if err != nil {
		return 0, fmt.Errorf("prune expired: %w", err)
	}
	return result.RowsAffected()
}

// GetArtifactsSince returns all artifacts for a topic since a given Unix timestamp.
func (s *Store) GetArtifactsSince(ctx context.Context, topicHash string, since int64) ([]Artifact, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT cid, payload, created_at FROM artifacts WHERE topic_hash = ? AND created_at >= ? ORDER BY created_at ASC`,
		topicHash, since,
	)
	if err != nil {
		return nil, fmt.Errorf("query artifacts: %w", err)
	}
	defer rows.Close()

	var artifacts []Artifact
	for rows.Next() {
		var a Artifact
		if err := rows.Scan(&a.CID, &a.Payload, &a.Timestamp); err != nil {
			return nil, fmt.Errorf("scan artifact: %w", err)
		}
		artifacts = append(artifacts, a)
	}
	return artifacts, rows.Err()
}

// UpsertPushToken inserts or updates a push token for a topic + device pair.
func (s *Store) UpsertPushToken(ctx context.Context, topicHash, deviceID, token string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO push_tokens (topic_hash, device_id, token, updated_at)
		 VALUES (?, ?, ?, strftime('%s', 'now'))
		 ON CONFLICT(topic_hash, device_id) DO UPDATE SET token = excluded.token, updated_at = excluded.updated_at`,
		topicHash, deviceID, token,
	)
	if err != nil {
		return fmt.Errorf("upsert push token: %w", err)
	}
	return nil
}

// GetPushTokens returns all push tokens registered for a given topic hash.
func (s *Store) GetPushTokens(ctx context.Context, topicHash string) ([]PushToken, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT topic_hash, device_id, token FROM push_tokens WHERE topic_hash = ?`,
		topicHash,
	)
	if err != nil {
		return nil, fmt.Errorf("query push tokens: %w", err)
	}
	defer rows.Close()

	var tokens []PushToken
	for rows.Next() {
		var t PushToken
		if err := rows.Scan(&t.TopicHash, &t.DeviceID, &t.Token); err != nil {
			return nil, fmt.Errorf("scan push token: %w", err)
		}
		tokens = append(tokens, t)
	}
	return tokens, rows.Err()
}

// Close closes the database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// --- Invites ---

// InsertInvite stores a single-use invite. Returns false if the token already exists.
func (s *Store) InsertInvite(ctx context.Context, token, payload, topicHash string, expiresAt int64) (bool, error) {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO invites (token, payload, topic_hash, expires_at) VALUES (?, ?, ?, ?)`,
		token, payload, topicHash, expiresAt,
	)
	if err != nil {
		if isUniqueViolation(err) {
			return false, nil
		}
		return false, fmt.Errorf("insert invite: %w", err)
	}
	return true, nil
}

// ClaimInvite atomically returns the invite payload and deletes it.
// Returns an error if the token doesn't exist or has expired.
func (s *Store) ClaimInvite(ctx context.Context, token string) (*Invite, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	var inv Invite
	err = tx.QueryRowContext(ctx,
		`SELECT token, payload, topic_hash, created_at, expires_at FROM invites WHERE token = ?`,
		token,
	).Scan(&inv.Token, &inv.Payload, &inv.TopicHash, &inv.CreatedAt, &inv.ExpiresAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("invite not found")
		}
		return nil, fmt.Errorf("query invite: %w", err)
	}

	now := time.Now().Unix()
	if inv.ExpiresAt <= now {
		// Expired — purge it and reject
		tx.ExecContext(ctx, `DELETE FROM invites WHERE token = ?`, token)
		tx.Commit()
		return nil, fmt.Errorf("invite expired")
	}

	// Purge on claim — single use, zero residual data
	_, err = tx.ExecContext(ctx, `DELETE FROM invites WHERE token = ?`, token)
	if err != nil {
		return nil, fmt.Errorf("delete invite: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit: %w", err)
	}

	return &inv, nil
}

// DeleteInvite removes an invite by token. Used for cleanup after handshake completion.
func (s *Store) DeleteInvite(ctx context.Context, token string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM invites WHERE token = ?`, token)
	if err != nil {
		return fmt.Errorf("delete invite: %w", err)
	}
	return nil
}

// PruneExpiredInvites deletes all invites past their expires_at timestamp.
func (s *Store) PruneExpiredInvites(ctx context.Context) (int64, error) {
	now := time.Now().Unix()
	result, err := s.db.ExecContext(ctx,
		`DELETE FROM invites WHERE expires_at <= ?`, now)
	if err != nil {
		return 0, fmt.Errorf("prune expired invites: %w", err)
	}
	return result.RowsAffected()
}

func isUniqueViolation(err error) bool {
	// SQLite unique constraint errors contain "UNIQUE constraint failed".
	var sqlErr error = err
	for sqlErr != nil {
		if sqlErr.Error() == "UNIQUE constraint failed: artifacts.cid" {
			return true
		}
		// Also check for the general pattern.
		if len(sqlErr.Error()) > 0 && contains(sqlErr.Error(), "UNIQUE constraint failed") {
			return true
		}
		sqlErr = errors.Unwrap(sqlErr)
	}
	return false
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchString(s, substr)
}

func searchString(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
