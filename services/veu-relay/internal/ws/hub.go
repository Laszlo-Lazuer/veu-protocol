package ws

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"sync"
	"time"

	"nhooyr.io/websocket"

	"github.com/veu-protocol/veu-relay/internal/push"
	"github.com/veu-protocol/veu-relay/internal/store"
)

const (
	maxMessageSize = 10 * 1024 * 1024 // 10 MB
	maxPayloadSize = 5 * 1024 * 1024  // 5 MB
	writeTimeout   = 10 * time.Second
	pingInterval   = 30 * time.Second
)

var topicHashRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ValidateTopicHash checks that a topic hash is exactly 64 lowercase hex characters.
func ValidateTopicHash(topic string) bool {
	return topicHashRe.MatchString(topic)
}

// --- Wire protocol message types ---

type IncomingMessage struct {
	Type     string `json:"type"`
	CID      string `json:"cid,omitempty"`
	Topic    string `json:"topic,omitempty"`
	Payload  string `json:"payload,omitempty"`
	Since    int64  `json:"since,omitempty"`
	Token    string `json:"token,omitempty"`
	DeviceID string `json:"device_id,omitempty"`
}

type ArtifactNotify struct {
	Type    string `json:"type"`
	CID     string `json:"cid"`
	Topic   string `json:"topic"`
	Payload string `json:"payload"`
}

type PullResponse struct {
	Type      string           `json:"type"`
	Artifacts []store.Artifact `json:"artifacts"`
}

type ErrorResponse struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

// --- Client ---

type Client struct {
	hub   *Hub
	conn  *websocket.Conn
	topic string
	send  chan []byte
}

// --- Hub ---

// Hub manages circle-scoped WebSocket channels.
type Hub struct {
	mu       sync.RWMutex
	circles  map[string]map[*Client]bool
	store    *store.Store
	pusher   *push.APNSPusher
	register chan *Client
	remove   chan *Client
}

// NewHub creates a new Hub wired to the given store and optional pusher.
func NewHub(st *store.Store, pusher *push.APNSPusher) *Hub {
	return &Hub{
		circles:  make(map[string]map[*Client]bool),
		store:    st,
		pusher:   pusher,
		register: make(chan *Client, 64),
		remove:   make(chan *Client, 64),
	}
}

// Run processes register/remove events. Blocks until ctx is cancelled.
func (h *Hub) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case c := <-h.register:
			h.mu.Lock()
			if h.circles[c.topic] == nil {
				h.circles[c.topic] = make(map[*Client]bool)
			}
			h.circles[c.topic][c] = true
			count := len(h.circles[c.topic])
			h.mu.Unlock()
			slog.Info("client connected", "topic", c.topic, "peers", count)

		case c := <-h.remove:
			h.mu.Lock()
			if clients, ok := h.circles[c.topic]; ok {
				delete(clients, c)
				if len(clients) == 0 {
					delete(h.circles, c.topic)
				}
			}
			h.mu.Unlock()
			close(c.send)
			slog.Info("client disconnected", "topic", c.topic)
		}
	}
}

// Broadcast sends data to all clients on the given topic except the sender.
func (h *Hub) Broadcast(topic string, sender *Client, data []byte) {
	h.mu.RLock()
	clients := h.circles[topic]
	h.mu.RUnlock()

	for c := range clients {
		if c == sender {
			continue
		}
		select {
		case c.send <- data:
		default:
			slog.Warn("slow client, dropping message", "topic", topic)
		}
	}
}

// OnlineDevicesForTopic returns the set of connected clients for a topic.
func (h *Hub) OnlineDevicesForTopic(topic string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.circles[topic])
}

// HandleWebSocket upgrades an HTTP connection and manages the client lifecycle.
func (h *Hub) HandleWebSocket(w http.ResponseWriter, r *http.Request) {
	topic := r.URL.Query().Get("topic")
	if !ValidateTopicHash(topic) {
		http.Error(w, `{"error":"invalid topic hash: must be 64 hex chars"}`, http.StatusBadRequest)
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true, // Allow any origin; TLS is expected at the load-balancer.
	})
	if err != nil {
		slog.Error("websocket accept failed", "error", err)
		return
	}
	conn.SetReadLimit(maxMessageSize)

	client := &Client{
		hub:   h,
		conn:  conn,
		topic: topic,
		send:  make(chan []byte, 256),
	}

	h.register <- client

	ctx := r.Context()
	go h.writePump(ctx, client)
	h.readPump(ctx, client)
}

func (h *Hub) readPump(ctx context.Context, c *Client) {
	defer func() {
		h.remove <- c
		c.conn.Close(websocket.StatusNormalClosure, "bye")
	}()

	for {
		_, data, err := c.conn.Read(ctx)
		if err != nil {
			if websocket.CloseStatus(err) == websocket.StatusNormalClosure ||
				websocket.CloseStatus(err) == websocket.StatusGoingAway {
				slog.Debug("client closed connection", "topic", c.topic)
			} else {
				slog.Debug("read error", "topic", c.topic, "error", err)
			}
			return
		}

		var msg IncomingMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			h.sendError(ctx, c, "invalid JSON")
			continue
		}

		switch msg.Type {
		case "artifact_push":
			h.handleArtifactPush(ctx, c, &msg)
		case "pull_request":
			h.handlePullRequest(ctx, c, &msg)
		case "register_token":
			h.handleRegisterToken(ctx, c, &msg)
		default:
			h.sendError(ctx, c, fmt.Sprintf("unknown message type: %s", msg.Type))
		}
	}
}

func (h *Hub) writePump(ctx context.Context, c *Client) {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-c.send:
			if !ok {
				return
			}
			writeCtx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.conn.Write(writeCtx, websocket.MessageText, msg)
			cancel()
			if err != nil {
				slog.Debug("write error", "topic", c.topic, "error", err)
				return
			}
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.conn.Ping(pingCtx)
			cancel()
			if err != nil {
				slog.Debug("ping failed", "topic", c.topic, "error", err)
				return
			}
		}
	}
}

func (h *Hub) handleArtifactPush(ctx context.Context, c *Client, msg *IncomingMessage) {
	if msg.CID == "" || msg.Topic == "" || msg.Payload == "" {
		h.sendError(ctx, c, "artifact_push requires cid, topic, and payload")
		return
	}
	if !ValidateTopicHash(msg.Topic) {
		h.sendError(ctx, c, "invalid topic hash")
		return
	}
	if msg.Topic != c.topic {
		h.sendError(ctx, c, "topic mismatch with connection")
		return
	}
	if len(msg.Payload) > maxPayloadSize {
		h.sendError(ctx, c, "payload exceeds maximum size")
		return
	}

	inserted, err := h.store.InsertArtifact(ctx, msg.CID, msg.Topic, msg.Payload)
	if err != nil {
		slog.Error("store insert failed", "cid", msg.CID, "error", err)
		h.sendError(ctx, c, "internal error")
		return
	}

	if !inserted {
		// Duplicate CID — already stored, skip broadcast.
		return
	}

	slog.Info("artifact stored", "cid", msg.CID, "topic", msg.Topic)

	// Broadcast to online peers.
	notify := ArtifactNotify{
		Type:    "artifact_notify",
		CID:     msg.CID,
		Topic:   msg.Topic,
		Payload: msg.Payload,
	}
	data, _ := json.Marshal(notify)
	h.Broadcast(msg.Topic, c, data)

	// Send APNs push to offline devices.
	if h.pusher != nil {
		go h.sendPushNotifications(ctx, msg.Topic, msg.CID)
	}
}

func (h *Hub) handlePullRequest(ctx context.Context, c *Client, msg *IncomingMessage) {
	if msg.Topic == "" {
		h.sendError(ctx, c, "pull_request requires topic")
		return
	}
	if !ValidateTopicHash(msg.Topic) {
		h.sendError(ctx, c, "invalid topic hash")
		return
	}

	artifacts, err := h.store.GetArtifactsSince(ctx, msg.Topic, msg.Since)
	if err != nil {
		slog.Error("store query failed", "topic", msg.Topic, "error", err)
		h.sendError(ctx, c, "internal error")
		return
	}

	if artifacts == nil {
		artifacts = []store.Artifact{}
	}

	resp := PullResponse{
		Type:      "pull_response",
		Artifacts: artifacts,
	}
	data, _ := json.Marshal(resp)

	select {
	case c.send <- data:
	default:
		slog.Warn("client send buffer full", "topic", c.topic)
	}
}

func (h *Hub) handleRegisterToken(ctx context.Context, c *Client, msg *IncomingMessage) {
	if msg.Topic == "" || msg.Token == "" || msg.DeviceID == "" {
		h.sendError(ctx, c, "register_token requires topic, token, and device_id")
		return
	}
	if !ValidateTopicHash(msg.Topic) {
		h.sendError(ctx, c, "invalid topic hash")
		return
	}

	if err := h.store.UpsertPushToken(ctx, msg.Topic, msg.DeviceID, msg.Token); err != nil {
		slog.Error("upsert push token failed", "error", err)
		h.sendError(ctx, c, "internal error")
		return
	}

	slog.Info("push token registered", "topic", msg.Topic, "device_id", msg.DeviceID)
}

func (h *Hub) sendPushNotifications(ctx context.Context, topicHash, cid string) {
	tokens, err := h.store.GetPushTokens(ctx, topicHash)
	if err != nil {
		slog.Error("failed to get push tokens", "topic", topicHash, "error", err)
		return
	}

	for _, t := range tokens {
		if err := h.pusher.Send(ctx, t.Token, cid); err != nil {
			slog.Warn("push notification failed", "device_id", t.DeviceID, "error", err)
		}
	}
}

func (h *Hub) sendError(ctx context.Context, c *Client, message string) {
	resp := ErrorResponse{
		Type:    "error",
		Message: message,
	}
	data, _ := json.Marshal(resp)
	select {
	case c.send <- data:
	default:
	}
}
