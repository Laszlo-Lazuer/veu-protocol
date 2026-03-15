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
hub := relay.NewHub(mgr)
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
