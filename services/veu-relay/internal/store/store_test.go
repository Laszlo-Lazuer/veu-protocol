package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func tempStore(t *testing.T) *Store {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	s, err := New(path)
	if err != nil {
		t.Fatalf("failed to create store: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestNewCreatesDatabase(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.db")
	s, err := New(path)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	defer s.Close()

	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Error("database file was not created")
	}
}

func TestInsertAndRetrieveArtifact(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	inserted, err := s.InsertArtifact(ctx, "cid-1", "topic-a", "encrypted-blob", nil)
	if err != nil {
		t.Fatalf("InsertArtifact() error = %v", err)
	}
	if !inserted {
		t.Error("expected inserted=true for new artifact")
	}

	arts, err := s.GetArtifactsSince(ctx, "topic-a", 0)
	if err != nil {
		t.Fatalf("GetArtifactsSince() error = %v", err)
	}
	if len(arts) != 1 {
		t.Fatalf("expected 1 artifact, got %d", len(arts))
	}
	if arts[0].CID != "cid-1" || arts[0].Payload != "encrypted-blob" {
		t.Errorf("artifact mismatch: %+v", arts[0])
	}
}

func TestDuplicateCIDIsSkipped(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	s.InsertArtifact(ctx, "cid-dup", "topic-a", "blob-1", nil)
	inserted, err := s.InsertArtifact(ctx, "cid-dup", "topic-a", "blob-2", nil)
	if err != nil {
		t.Fatalf("InsertArtifact() error = %v", err)
	}
	if inserted {
		t.Error("expected inserted=false for duplicate CID")
	}
}

func TestArtifactsAreTopicScoped(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	s.InsertArtifact(ctx, "cid-1", "topic-a", "blob-a", nil)
	s.InsertArtifact(ctx, "cid-2", "topic-b", "blob-b", nil)

	arts, _ := s.GetArtifactsSince(ctx, "topic-a", 0)
	if len(arts) != 1 || arts[0].CID != "cid-1" {
		t.Errorf("topic-a should have exactly cid-1, got %+v", arts)
	}

	arts, _ = s.GetArtifactsSince(ctx, "topic-b", 0)
	if len(arts) != 1 || arts[0].CID != "cid-2" {
		t.Errorf("topic-b should have exactly cid-2, got %+v", arts)
	}
}

func TestUpsertAndGetPushTokens(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	if err := s.UpsertPushToken(ctx, "topic-a", "device-1", "token-abc"); err != nil {
		t.Fatalf("UpsertPushToken() error = %v", err)
	}

	tokens, err := s.GetPushTokens(ctx, "topic-a")
	if err != nil {
		t.Fatalf("GetPushTokens() error = %v", err)
	}
	if len(tokens) != 1 || tokens[0].Token != "token-abc" {
		t.Errorf("expected token-abc, got %+v", tokens)
	}

	// Upsert overwrites
	s.UpsertPushToken(ctx, "topic-a", "device-1", "token-xyz")
	tokens, _ = s.GetPushTokens(ctx, "topic-a")
	if len(tokens) != 1 || tokens[0].Token != "token-xyz" {
		t.Errorf("expected token-xyz after upsert, got %+v", tokens)
	}
}

func TestGetArtifactsSinceEmpty(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	arts, err := s.GetArtifactsSince(ctx, "nonexistent", 0)
	if err != nil {
		t.Fatalf("GetArtifactsSince() error = %v", err)
	}
	if arts != nil {
		t.Errorf("expected nil for empty result, got %+v", arts)
	}
}

func TestGetPushTokensEmpty(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	tokens, err := s.GetPushTokens(ctx, "nonexistent")
	if err != nil {
		t.Fatalf("GetPushTokens() error = %v", err)
	}
	if tokens != nil {
		t.Errorf("expected nil for empty result, got %+v", tokens)
	}
}

func TestInsertArtifactWithBurnAfter(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	burn := int64(time.Now().Unix() + 3600) // 1 hour from now
	inserted, err := s.InsertArtifact(ctx, "cid-burn", "topic-a", "blob", &burn)
	if err != nil {
		t.Fatalf("InsertArtifact() error = %v", err)
	}
	if !inserted {
		t.Error("expected inserted=true")
	}

	arts, _ := s.GetArtifactsSince(ctx, "topic-a", 0)
	if len(arts) != 1 || arts[0].CID != "cid-burn" {
		t.Fatalf("expected artifact cid-burn, got %+v", arts)
	}
}

func TestPruneExpiredDeletesOldArtifacts(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	past := int64(time.Now().Unix() - 60) // expired 60s ago
	future := int64(time.Now().Unix() + 3600)

	s.InsertArtifact(ctx, "expired-1", "topic-a", "blob1", &past)
	s.InsertArtifact(ctx, "alive-1", "topic-a", "blob2", &future)
	s.InsertArtifact(ctx, "permanent", "topic-a", "blob3", nil) // no burn_after

	pruned, err := s.PruneExpired(ctx)
	if err != nil {
		t.Fatalf("PruneExpired() error = %v", err)
	}
	if pruned != 1 {
		t.Errorf("expected 1 pruned, got %d", pruned)
	}

	arts, _ := s.GetArtifactsSince(ctx, "topic-a", 0)
	if len(arts) != 2 {
		t.Fatalf("expected 2 remaining artifacts, got %d", len(arts))
	}
	for _, a := range arts {
		if a.CID == "expired-1" {
			t.Error("expired artifact should have been pruned")
		}
	}
}

func TestDeleteArtifact(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	s.InsertArtifact(ctx, "cid-del", "topic-a", "blob", nil)

	if err := s.DeleteArtifact(ctx, "cid-del"); err != nil {
		t.Fatalf("DeleteArtifact() error = %v", err)
	}

	arts, _ := s.GetArtifactsSince(ctx, "topic-a", 0)
	if len(arts) != 0 {
		t.Errorf("expected 0 artifacts after delete, got %d", len(arts))
	}
}

func TestDeleteArtifactNonExistent(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	// Should not error on non-existent CID
	if err := s.DeleteArtifact(ctx, "no-such-cid"); err != nil {
		t.Fatalf("DeleteArtifact() error = %v", err)
	}
}

// --- Invite tests ---

func TestInsertAndClaimInvite(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	expiresAt := time.Now().Unix() + 3600
	inserted, err := s.InsertInvite(ctx, "token-abc", "offer-payload", "topic-hash-1", expiresAt)
	if err != nil {
		t.Fatalf("InsertInvite() error = %v", err)
	}
	if !inserted {
		t.Error("expected inserted=true for new invite")
	}

	inv, err := s.ClaimInvite(ctx, "token-abc")
	if err != nil {
		t.Fatalf("ClaimInvite() error = %v", err)
	}
	if inv.Token != "token-abc" || inv.Payload != "offer-payload" || inv.TopicHash != "topic-hash-1" {
		t.Errorf("invite mismatch: %+v", inv)
	}
}

func TestClaimInvitePurgesRecord(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	expiresAt := time.Now().Unix() + 3600
	s.InsertInvite(ctx, "token-purge", "payload", "topic", expiresAt)

	// First claim succeeds
	_, err := s.ClaimInvite(ctx, "token-purge")
	if err != nil {
		t.Fatalf("first ClaimInvite() error = %v", err)
	}

	// Second claim fails — record is gone
	_, err = s.ClaimInvite(ctx, "token-purge")
	if err == nil {
		t.Fatal("expected error on second claim, got nil")
	}
	if err.Error() != "invite not found" {
		t.Errorf("expected 'invite not found', got %q", err.Error())
	}
}

func TestClaimInviteNonExistent(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	_, err := s.ClaimInvite(ctx, "no-such-token")
	if err == nil {
		t.Fatal("expected error for non-existent invite")
	}
	if err.Error() != "invite not found" {
		t.Errorf("expected 'invite not found', got %q", err.Error())
	}
}

func TestClaimInviteExpired(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	past := time.Now().Unix() - 60
	s.InsertInvite(ctx, "token-expired", "payload", "topic", past)

	_, err := s.ClaimInvite(ctx, "token-expired")
	if err == nil {
		t.Fatal("expected error for expired invite")
	}
	if err.Error() != "invite expired" {
		t.Errorf("expected 'invite expired', got %q", err.Error())
	}

	// Verify the expired invite was also purged
	_, err = s.ClaimInvite(ctx, "token-expired")
	if err == nil || err.Error() != "invite not found" {
		t.Errorf("expired invite should be purged, got %v", err)
	}
}

func TestInsertInviteDuplicateToken(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	expiresAt := time.Now().Unix() + 3600
	s.InsertInvite(ctx, "token-dup", "payload1", "topic1", expiresAt)

	inserted, err := s.InsertInvite(ctx, "token-dup", "payload2", "topic2", expiresAt)
	if err != nil {
		t.Fatalf("InsertInvite() error = %v", err)
	}
	if inserted {
		t.Error("expected inserted=false for duplicate token")
	}
}

func TestPruneExpiredInvites(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	past := time.Now().Unix() - 60
	future := time.Now().Unix() + 3600

	s.InsertInvite(ctx, "expired-inv", "p1", "t1", past)
	s.InsertInvite(ctx, "alive-inv", "p2", "t2", future)

	pruned, err := s.PruneExpiredInvites(ctx)
	if err != nil {
		t.Fatalf("PruneExpiredInvites() error = %v", err)
	}
	if pruned != 1 {
		t.Errorf("expected 1 pruned invite, got %d", pruned)
	}

	// Alive invite should still be claimable
	inv, err := s.ClaimInvite(ctx, "alive-inv")
	if err != nil {
		t.Fatalf("ClaimInvite() error = %v", err)
	}
	if inv.Payload != "p2" {
		t.Errorf("expected payload p2, got %s", inv.Payload)
	}

	// Expired invite should be gone
	_, err = s.ClaimInvite(ctx, "expired-inv")
	if err == nil {
		t.Error("expected error for pruned invite")
	}
}

func TestDeleteInvite(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()

	expiresAt := time.Now().Unix() + 3600
	s.InsertInvite(ctx, "token-del", "payload", "topic", expiresAt)

	if err := s.DeleteInvite(ctx, "token-del"); err != nil {
		t.Fatalf("DeleteInvite() error = %v", err)
	}

	_, err := s.ClaimInvite(ctx, "token-del")
	if err == nil || err.Error() != "invite not found" {
		t.Errorf("expected 'invite not found' after delete, got %v", err)
	}
}
