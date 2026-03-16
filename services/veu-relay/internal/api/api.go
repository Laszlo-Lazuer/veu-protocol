package api

import (
	"encoding/json"
	"net/http"

	"github.com/veu-protocol/veu-relay/internal/store"
	"github.com/veu-protocol/veu-relay/internal/ws"
)

const version = "0.1.0"

// NewRouter returns an http.ServeMux with all relay routes registered.
func NewRouter(hub *ws.Hub, st *store.Store, adminToken string) *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", handleHealth)
	mux.HandleFunc("GET /ws", hub.HandleWebSocket)

	if adminToken != "" {
		admin := &adminHandler{store: st, token: adminToken}
		mux.HandleFunc("GET /admin/stats", admin.requireAuth(admin.handleStats))
		mux.HandleFunc("DELETE /admin/artifacts", admin.requireAuth(admin.handlePurgeArtifacts))
	}

	return mux
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"version": version,
	})
}

// --- Admin handlers ---

type adminHandler struct {
	store *store.Store
	token string
}

func (a *adminHandler) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		if token != "Bearer "+a.token {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (a *adminHandler) handleStats(w http.ResponseWriter, r *http.Request) {
	artifacts, pushTokens, invites, _ := a.store.Stats(r.Context())
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]int64{
		"artifacts":   artifacts,
		"push_tokens": pushTokens,
		"invites":     invites,
	})
}

func (a *adminHandler) handlePurgeArtifacts(w http.ResponseWriter, r *http.Request) {
	topic := r.URL.Query().Get("topic")
	var deleted int64
	var err error

	if topic != "" {
		deleted, err = a.store.PurgeArtifactsByTopic(r.Context(), topic)
	} else {
		deleted, err = a.store.PurgeAllArtifacts(r.Context())
	}

	if err != nil {
		http.Error(w, `{"error":"internal error"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"status":  "ok",
		"deleted": deleted,
	})
}
