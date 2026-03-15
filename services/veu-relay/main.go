package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/veu-protocol/veu-relay/internal/api"
	"github.com/veu-protocol/veu-relay/internal/push"
	"github.com/veu-protocol/veu-relay/internal/store"
	"github.com/veu-protocol/veu-relay/internal/ws"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := envOrDefault("VEU_RELAY_PORT", "8080")
	dbPath := envOrDefault("VEU_RELAY_DB_PATH", "./veu-relay.db")

	portNum, err := strconv.Atoi(port)
	if err != nil || portNum < 1 || portNum > 65535 {
		slog.Error("invalid port", "port", port)
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize SQLite store.
	st, err := store.New(dbPath)
	if err != nil {
		slog.Error("failed to open store", "error", err)
		os.Exit(1)
	}
	defer st.Close()

	// Initialize optional APNs pusher.
	var pusher *push.APNSPusher
	apnsKeyPath := os.Getenv("VEU_APNS_KEY_PATH")
	apnsKeyID := os.Getenv("VEU_APNS_KEY_ID")
	apnsTeamID := os.Getenv("VEU_APNS_TEAM_ID")
	apnsTopic := os.Getenv("VEU_APNS_TOPIC")

	if apnsKeyPath != "" && apnsKeyID != "" && apnsTeamID != "" && apnsTopic != "" {
		pusher, err = push.NewAPNSPusher(apnsKeyPath, apnsKeyID, apnsTeamID, apnsTopic)
		if err != nil {
			slog.Error("failed to initialize APNs", "error", err)
			os.Exit(1)
		}
		slog.Info("APNs push enabled", "topic", apnsTopic)
	} else {
		slog.Info("APNs push disabled (missing config)")
	}

	// Initialize WebSocket hub.
	hub := ws.NewHub(st, pusher)
	go hub.Run(ctx)
	hub.StartPruner(ctx, 5*time.Minute)

	// Set up HTTP routes.
	mux := api.NewRouter(hub)
	addr := ":" + port

	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in goroutine.
	go func() {
		slog.Info("veu-relay starting", "port", port, "db", dbPath)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	// Wait for shutdown signal.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	slog.Info("received shutdown signal", "signal", sig)

	cancel()

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown error", "error", err)
	}

	slog.Info("veu-relay stopped")
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
