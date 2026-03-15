package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/veu-protocol/veu-voice-relay/internal/api"
	"github.com/veu-protocol/veu-voice-relay/internal/push"
	"github.com/veu-protocol/veu-voice-relay/internal/relay"
	"github.com/veu-protocol/veu-voice-relay/internal/session"
)

func main() {
logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
slog.SetDefault(logger)

port := envOrDefault("VEU_VOICE_RELAY_PORT", "8080")

ctx, cancel := context.WithCancel(context.Background())
defer cancel()

	mgr := session.NewManager()

	// Configure APNs push client (optional — works without it, just can't wake offline callees)
	var pusher *push.Client
	apnsKeyPath := os.Getenv("VEU_APNS_KEY_PATH")
	apnsKeyContent := os.Getenv("VEU_APNS_KEY_CONTENT")
	apnsKeyID := os.Getenv("VEU_APNS_KEY_ID")
	apnsTeamID := os.Getenv("VEU_APNS_TEAM_ID")
	apnsBundleID := envOrDefault("VEU_APNS_BUNDLE_ID", "com.squirrelyeye.veu")
	apnsSandbox := os.Getenv("VEU_APNS_SANDBOX") == "true"

	if (apnsKeyPath != "" || apnsKeyContent != "") && apnsKeyID != "" && apnsTeamID != "" {
		var err error
		pusher, err = push.NewClient(push.Config{
			KeyPath:    apnsKeyPath,
			KeyContent: apnsKeyContent,
			KeyID:      apnsKeyID,
			TeamID:     apnsTeamID,
			BundleID:   apnsBundleID,
			Sandbox:    apnsSandbox,
		})
		if err != nil {
			slog.Error("APNs client init failed (push disabled)", "error", err)
		} else {
			slog.Info("APNs push enabled", "key_id", apnsKeyID, "sandbox", apnsSandbox)
		}
	} else {
		slog.Info("APNs push disabled (no key configured)")
	}

	hub := relay.NewHub(mgr, pusher)
mux := api.NewRouter(hub)

go hub.StartCleanup(ctx)

addr := ":" + port
srv := &http.Server{
Addr:         addr,
Handler:      mux,
ReadTimeout:  15 * time.Second,
WriteTimeout: 15 * time.Second,
IdleTimeout:  60 * time.Second,
}

go func() {
slog.Info("server starting", "port", port)
if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
slog.Error("server error", "error", err)
os.Exit(1)
}
}()

quit := make(chan os.Signal, 1)
signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
<-quit

slog.Info("shutting down server")
cancel()

shutCtx, shutCancel := context.WithTimeout(context.Background(), 10*time.Second)
defer shutCancel()

if err := srv.Shutdown(shutCtx); err != nil {
slog.Error("server shutdown error", "error", err)
}

slog.Info("server stopped")
}

func envOrDefault(key, fallback string) string {
if v := os.Getenv(key); v != "" {
return v
}
return fallback
}
