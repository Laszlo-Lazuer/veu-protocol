package api

import (
	"encoding/json"
	"net/http"

	"github.com/veu-protocol/veu-voice-relay/internal/relay"
)

const version = "0.1.0"

// NewRouter returns an http.ServeMux with all voice relay routes registered.
func NewRouter(hub *relay.Hub) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", handleHealth)
	mux.HandleFunc("GET /ws", hub.HandleWebSocket)
	return mux
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"version": version,
	})
}
