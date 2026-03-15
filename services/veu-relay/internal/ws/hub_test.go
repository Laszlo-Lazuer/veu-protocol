package ws

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/veu-protocol/veu-relay/internal/store"
)

func TestValidateTopicHash(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  bool
	}{
		{"valid 64-char hex", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", true},
		{"valid all zeros", "0000000000000000000000000000000000000000000000000000000000000000", true},
		{"valid all f's", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", true},
		{"too short", "a1b2c3d4", false},
		{"too long", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2ff", false},
		{"uppercase rejected", "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2", false},
		{"non-hex chars", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", false},
		{"empty string", "", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ValidateTopicHash(tt.input); got != tt.want {
				t.Errorf("ValidateTopicHash(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

func TestArtifactPushAcceptedAck(t *testing.T) {
	hub, st, server := newTestHubServer(t)
	conn := dialTestWebSocket(t, server.URL, validTopicHash)
	defer conn.Close(websocket.StatusNormalClosure, "")

	sendJSON(t, conn, map[string]any{
		"type":    "artifact_push",
		"cid":     "cid-1",
		"topic":   validTopicHash,
		"payload": "encrypted-blob",
	})

	var ack ArtifactAck
	readJSON(t, conn, &ack)

	if ack.Status != "accepted" {
		t.Fatalf("expected accepted ack, got %+v", ack)
	}

	artifacts, err := st.GetArtifactsSince(context.Background(), validTopicHash, 0)
	if err != nil {
		t.Fatalf("GetArtifactsSince() error = %v", err)
	}
	if len(artifacts) != 1 || artifacts[0].CID != "cid-1" {
		t.Fatalf("expected stored artifact cid-1, got %+v", artifacts)
	}

	_ = hub
}

func TestArtifactPushDuplicateAck(t *testing.T) {
	_, _, server := newTestHubServer(t)
	conn := dialTestWebSocket(t, server.URL, validTopicHash)
	defer conn.Close(websocket.StatusNormalClosure, "")

	push := map[string]any{
		"type":    "artifact_push",
		"cid":     "cid-dup",
		"topic":   validTopicHash,
		"payload": "encrypted-blob",
	}

	sendJSON(t, conn, push)
	var first ArtifactAck
	readJSON(t, conn, &first)
	if first.Status != "accepted" {
		t.Fatalf("expected accepted ack, got %+v", first)
	}

	sendJSON(t, conn, push)
	var second ArtifactAck
	readJSON(t, conn, &second)
	if second.Status != "duplicate" {
		t.Fatalf("expected duplicate ack, got %+v", second)
	}
}

func TestEphemeralArtifactPushDoesNotPersist(t *testing.T) {
	_, st, server := newTestHubServer(t)
	conn := dialTestWebSocket(t, server.URL, validTopicHash)
	defer conn.Close(websocket.StatusNormalClosure, "")

	sendJSON(t, conn, map[string]any{
		"type":    "artifact_push",
		"cid":     "sync-request-1",
		"topic":   validTopicHash,
		"payload": "encrypted-blob",
		"persist": false,
	})

	var ack ArtifactAck
	readJSON(t, conn, &ack)

	if ack.Status != "accepted" {
		t.Fatalf("expected accepted ack for ephemeral push, got %+v", ack)
	}

	artifacts, err := st.GetArtifactsSince(context.Background(), validTopicHash, 0)
	if err != nil {
		t.Fatalf("GetArtifactsSince() error = %v", err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("expected no persisted artifacts, got %+v", artifacts)
	}
}

func TestArtifactPushWithBurnAfter(t *testing.T) {
	_, st, server := newTestHubServer(t)
	conn := dialTestWebSocket(t, server.URL, validTopicHash)
	defer conn.Close(websocket.StatusNormalClosure, "")

	burnAfter := time.Now().Unix() + 3600

	sendJSON(t, conn, map[string]any{
		"type":       "artifact_push",
		"cid":        "cid-ephemeral",
		"topic":      validTopicHash,
		"payload":    "encrypted-blob",
		"burn_after": burnAfter,
	})

	var ack ArtifactAck
	readJSON(t, conn, &ack)

	if ack.Status != "accepted" {
		t.Fatalf("expected accepted ack, got %+v", ack)
	}

	artifacts, err := st.GetArtifactsSince(context.Background(), validTopicHash, 0)
	if err != nil {
		t.Fatalf("GetArtifactsSince() error = %v", err)
	}
	if len(artifacts) != 1 || artifacts[0].CID != "cid-ephemeral" {
		t.Fatalf("expected stored artifact, got %+v", artifacts)
	}
}

func TestBurnNoticeDeletesArtifact(t *testing.T) {
	_, st, server := newTestHubServer(t)
	conn := dialTestWebSocket(t, server.URL, validTopicHash)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// First store an artifact
	sendJSON(t, conn, map[string]any{
		"type":    "artifact_push",
		"cid":     "cid-to-burn",
		"topic":   validTopicHash,
		"payload": "encrypted-blob",
	})

	var ack ArtifactAck
	readJSON(t, conn, &ack)
	if ack.Status != "accepted" {
		t.Fatalf("expected accepted, got %+v", ack)
	}

	// Verify it's stored
	arts, _ := st.GetArtifactsSince(context.Background(), validTopicHash, 0)
	if len(arts) != 1 {
		t.Fatalf("expected 1 stored artifact, got %d", len(arts))
	}

	// Send burn notice
	sendJSON(t, conn, map[string]any{
		"type":  "burn_notice",
		"cid":   "cid-to-burn",
		"topic": validTopicHash,
	})

	// Small delay for processing
	time.Sleep(100 * time.Millisecond)

	// Verify it's deleted
	arts, _ = st.GetArtifactsSince(context.Background(), validTopicHash, 0)
	if len(arts) != 0 {
		t.Fatalf("expected 0 artifacts after burn, got %d", len(arts))
	}
}

const validTopicHash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

func newTestHubServer(t *testing.T) (*Hub, *store.Store, *httptest.Server) {
	t.Helper()

	path := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.New(path)
	if err != nil {
		t.Fatalf("store.New() error = %v", err)
	}

	hub := NewHub(st, nil)
	ctx, cancel := context.WithCancel(context.Background())
	go hub.Run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", hub.HandleWebSocket)
	server := httptest.NewServer(mux)

	t.Cleanup(func() {
		cancel()
		server.Close()
		st.Close()
	})

	return hub, st, server
}

func dialTestWebSocket(t *testing.T, serverURL, topic string) *websocket.Conn {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(serverURL, "http") + "/ws?topic=" + topic
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket.Dial() error = %v", err)
	}
	return conn
}

func sendJSON(t *testing.T, conn *websocket.Conn, payload any) {
	t.Helper()

	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("conn.Write() error = %v", err)
	}
}

func readJSON(t *testing.T, conn *websocket.Conn, out any) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("conn.Read() error = %v", err)
	}

	if err := json.Unmarshal(data, out); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}
}
