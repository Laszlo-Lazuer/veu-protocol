package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
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

	inserted, err := s.InsertArtifact(ctx, "cid-1", "topic-a", "encrypted-blob")
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

	s.InsertArtifact(ctx, "cid-dup", "topic-a", "blob-1")
	inserted, err := s.InsertArtifact(ctx, "cid-dup", "topic-a", "blob-2")
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

	s.InsertArtifact(ctx, "cid-1", "topic-a", "blob-a")
	s.InsertArtifact(ctx, "cid-2", "topic-b", "blob-b")

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
