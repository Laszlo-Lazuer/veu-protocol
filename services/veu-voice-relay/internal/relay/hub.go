package relay

import (
"context"
"encoding/json"
"log/slog"
"net/http"
"strings"
"time"

"github.com/veu-protocol/veu-voice-relay/internal/auth"
"github.com/veu-protocol/veu-voice-relay/internal/session"
"nhooyr.io/websocket"
)

const (
maxMessageSize  = 64 * 1024 // 64KB
writeTimeout    = 10 * time.Second
callIDLength    = 36 // UUID string length
cleanupInterval = 10 * time.Second
idleTimeout     = 60 * time.Second
maxCallDuration = 1 * time.Hour
)

// SignalingMessage is the JSON wire format for all signaling messages.
type SignalingMessage struct {
Type           string `json:"type"`
DeviceID       string `json:"device_id,omitempty"`
CircleID       string `json:"circle_id,omitempty"`
CallID         string `json:"call_id,omitempty"`
TargetDeviceID string `json:"target_device_id,omitempty"`
CallerDeviceID string `json:"caller_device_id,omitempty"`
SDP            string `json:"sdp,omitempty"`
Reason         string `json:"reason,omitempty"`
Candidate      string `json:"candidate,omitempty"`
Message        string `json:"message,omitempty"`
// Auth fields (register only)
PublicKey string `json:"public_key,omitempty"`
Timestamp string `json:"timestamp,omitempty"`
Signature string `json:"signature,omitempty"`
}

// Hub manages WebSocket connections and routes signaling and audio frames.
type Hub struct {
manager  *session.Manager
verifier *auth.Verifier
}

func NewHub(mgr *session.Manager) *Hub {
return &Hub{manager: mgr, verifier: auth.NewVerifier()}
}

func (h *Hub) HandleWebSocket(w http.ResponseWriter, r *http.Request) {
conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
InsecureSkipVerify: true,
})
if err != nil {
slog.Error("websocket accept failed", "error", err)
return
}
conn.SetReadLimit(maxMessageSize)

h.readPump(r.Context(), conn)
}

func (h *Hub) readPump(ctx context.Context, conn *websocket.Conn) {
var deviceKey string

defer func() {
if deviceKey != "" {
h.onDisconnect(deviceKey)
}
conn.CloseNow()
}()

for {
msgType, data, err := conn.Read(ctx)
if err != nil {
if websocket.CloseStatus(err) == websocket.StatusNormalClosure ||
websocket.CloseStatus(err) == websocket.StatusGoingAway {
slog.Debug("client disconnected", "device_key", deviceKey)
} else {
slog.Debug("websocket read error", "error", err, "device_key", deviceKey)
}
return
}

switch msgType {
case websocket.MessageText:
h.handleSignaling(ctx, conn, data, &deviceKey)
case websocket.MessageBinary:
h.handleAudioFrame(ctx, conn, data, deviceKey)
}
}
}

func (h *Hub) handleSignaling(ctx context.Context, conn *websocket.Conn, data []byte, deviceKey *string) {
var msg SignalingMessage
if err := json.Unmarshal(data, &msg); err != nil {
h.sendError(conn, "invalid JSON")
return
}

switch msg.Type {
case "register":
h.handleRegister(conn, msg, deviceKey)
case "call_offer":
h.handleCallOffer(ctx, conn, msg, *deviceKey)
case "call_answer":
h.handleCallAnswer(conn, msg, *deviceKey)
case "call_end":
h.handleCallEnd(conn, msg, *deviceKey)
case "ice_candidate":
h.handleICECandidate(conn, msg, *deviceKey)
default:
h.sendError(conn, "unknown message type")
}
}

func (h *Hub) handleRegister(conn *websocket.Conn, msg SignalingMessage, deviceKey *string) {
if msg.DeviceID == "" || msg.CircleID == "" {
	h.sendError(conn, "device_id and circle_id required")
	return
}
if msg.PublicKey == "" || msg.Timestamp == "" || msg.Signature == "" {
	h.sendError(conn, "public_key, timestamp, and signature required")
	return
}

if err := h.verifier.VerifyRegister(msg.DeviceID, msg.CircleID, msg.PublicKey, msg.Timestamp, msg.Signature); err != nil {
	slog.Warn("register auth failed", "error", err, "device_id", msg.DeviceID)
	h.sendError(conn, "authentication failed: "+err.Error())
	return
}

key := msg.CircleID + ":" + msg.DeviceID
h.manager.RegisterDevice(key, conn)
*deviceKey = key
slog.Info("device registered", "device_key", key)
}

func (h *Hub) handleCallOffer(ctx context.Context, conn *websocket.Conn, msg SignalingMessage, senderKey string) {
if senderKey == "" {
h.sendError(conn, "must register before making calls")
return
}
if msg.CallID == "" || msg.TargetDeviceID == "" {
h.sendError(conn, "call_id and target_device_id required")
return
}

circleID := senderKey[:strings.Index(senderKey, ":")]
targetKey := circleID + ":" + msg.TargetDeviceID

targetConn, ok := h.manager.GetDeviceConn(targetKey)
if !ok {
h.sendError(conn, "target device not connected")
return
}

callerDeviceID := senderKey[strings.Index(senderKey, ":")+1:]
h.manager.CreateSession(msg.CallID, senderKey, targetKey, conn)

offer := SignalingMessage{
Type:           "call_offer",
CallID:         msg.CallID,
CallerDeviceID: callerDeviceID,
SDP:            msg.SDP,
}
if err := h.writeJSON(targetConn, offer); err != nil {
slog.Error("failed to forward offer", "error", err, "call_id", msg.CallID)
h.manager.EndSession(msg.CallID)
return
}

h.manager.SetSessionRinging(msg.CallID)

ringing := SignalingMessage{Type: "call_ringing", CallID: msg.CallID}
h.writeJSON(conn, ringing)

slog.Info("call offer forwarded", "call_id", msg.CallID, "from", senderKey, "to", targetKey)
}

func (h *Hub) handleCallAnswer(conn *websocket.Conn, msg SignalingMessage, senderKey string) {
if senderKey == "" {
h.sendError(conn, "must register before answering calls")
return
}
if msg.CallID == "" {
h.sendError(conn, "call_id required")
return
}

s, ok := h.manager.GetSession(msg.CallID)
if !ok {
h.sendError(conn, "call not found")
return
}
if s.CalleeKey != senderKey {
h.sendError(conn, "not the intended callee")
return
}
if _, ok := h.manager.ActivateSession(msg.CallID, conn); !ok {
h.sendError(conn, "call cannot be answered")
return
}

answer := SignalingMessage{
Type:   "call_answer",
CallID: msg.CallID,
SDP:    msg.SDP,
}
if err := h.writeJSON(s.CallerConn, answer); err != nil {
slog.Error("failed to forward answer", "error", err, "call_id", msg.CallID)
}

slog.Info("call answered", "call_id", msg.CallID, "callee", senderKey)
}

func (h *Hub) handleCallEnd(conn *websocket.Conn, msg SignalingMessage, senderKey string) {
if msg.CallID == "" {
h.sendError(conn, "call_id required")
return
}

s, ok := h.manager.EndSession(msg.CallID)
if !ok {
return
}

reason := msg.Reason
if reason == "" {
reason = "user_hangup"
}

endMsg := SignalingMessage{
Type:   "call_end",
CallID: msg.CallID,
Reason: reason,
}

var peerConn *websocket.Conn
if senderKey == s.CallerKey {
peerConn = s.CalleeConn
} else {
peerConn = s.CallerConn
}
if peerConn != nil {
h.writeJSON(peerConn, endMsg)
}

slog.Info("call ended", "call_id", msg.CallID, "reason", reason, "by", senderKey)
}

func (h *Hub) handleICECandidate(conn *websocket.Conn, msg SignalingMessage, senderKey string) {
if senderKey == "" {
h.sendError(conn, "must register before sending ICE candidates")
return
}
if msg.CallID == "" || msg.Candidate == "" {
h.sendError(conn, "call_id and candidate required")
return
}

peerConn, ok := h.manager.GetPeerConn(msg.CallID, senderKey)
if !ok {
return
}

fwd := SignalingMessage{
Type:      "ice_candidate",
CallID:    msg.CallID,
Candidate: msg.Candidate,
}
if err := h.writeJSON(peerConn, fwd); err != nil {
slog.Error("failed to forward ICE candidate", "error", err, "call_id", msg.CallID)
}
}

func (h *Hub) handleAudioFrame(_ context.Context, _ *websocket.Conn, data []byte, deviceKey string) {
if deviceKey == "" || len(data) < callIDLength {
return
}

callID := string(data[:callIDLength])
peerConn, ok := h.manager.GetPeerConn(callID, deviceKey)
if !ok {
return
}

h.manager.TouchSession(callID)

ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
defer cancel()
if err := peerConn.Write(ctx, websocket.MessageBinary, data); err != nil {
slog.Debug("failed to forward audio frame", "error", err, "call_id", callID)
}
}

func (h *Hub) onDisconnect(deviceKey string) {
sessions := h.manager.EndSessionsForDevice(deviceKey)
h.manager.UnregisterDevice(deviceKey)

for _, s := range sessions {
endMsg := SignalingMessage{
Type:   "call_end",
CallID: s.CallID,
Reason: "peer_disconnected",
}

var peerConn *websocket.Conn
if deviceKey == s.CallerKey {
peerConn = s.CalleeConn
} else {
peerConn = s.CallerConn
}
if peerConn != nil {
h.writeJSON(peerConn, endMsg)
}
}

slog.Info("device disconnected", "device_key", deviceKey)
}

// StartCleanup periodically removes expired sessions and notifies participants.
func (h *Hub) StartCleanup(ctx context.Context) {
ticker := time.NewTicker(cleanupInterval)
defer ticker.Stop()

for {
select {
case <-ctx.Done():
return
case <-ticker.C:
expired := h.manager.CleanupExpired(idleTimeout, maxCallDuration)
for _, s := range expired {
endMsg := SignalingMessage{
Type:   "call_end",
CallID: s.CallID,
Reason: "timeout",
}
if s.CallerConn != nil {
h.writeJSON(s.CallerConn, endMsg)
}
if s.CalleeConn != nil {
h.writeJSON(s.CalleeConn, endMsg)
}
}
}
}
}

func (h *Hub) writeJSON(conn *websocket.Conn, v any) error {
data, err := json.Marshal(v)
if err != nil {
return err
}
ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
defer cancel()
return conn.Write(ctx, websocket.MessageText, data)
}

func (h *Hub) sendError(conn *websocket.Conn, message string) {
h.writeJSON(conn, SignalingMessage{Type: "error", Message: message})
}
