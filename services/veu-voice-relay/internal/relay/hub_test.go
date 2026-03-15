package relay

import (
"context"
"encoding/json"
"net/http"
"net/http/httptest"
"testing"
"time"

"github.com/veu-protocol/veu-voice-relay/internal/session"
"nhooyr.io/websocket"
)

func newTestServer(t *testing.T) (*httptest.Server, *Hub) {
t.Helper()
mgr := session.NewManager()
hub := NewHub(mgr)

mux := http.NewServeMux()
mux.HandleFunc("GET /ws", hub.HandleWebSocket)

srv := httptest.NewServer(mux)
t.Cleanup(srv.Close)
return srv, hub
}

func dialWS(t *testing.T, srv *httptest.Server) *websocket.Conn {
t.Helper()
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()

conn, _, err := websocket.Dial(ctx, "ws"+srv.URL[4:]+"/ws", nil)
if err != nil {
t.Fatalf("dial: %v", err)
}
t.Cleanup(func() { conn.CloseNow() })
return conn
}

func sendJSON(t *testing.T, conn *websocket.Conn, v any) {
t.Helper()
data, err := json.Marshal(v)
if err != nil {
t.Fatalf("marshal: %v", err)
}
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()
if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
t.Fatalf("write: %v", err)
}
}

func readJSON(t *testing.T, conn *websocket.Conn) SignalingMessage {
t.Helper()
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()
_, data, err := conn.Read(ctx)
if err != nil {
t.Fatalf("read: %v", err)
}
var msg SignalingMessage
if err := json.Unmarshal(data, &msg); err != nil {
t.Fatalf("unmarshal: %v", err)
}
return msg
}

func register(t *testing.T, conn *websocket.Conn, circleID, deviceID string) {
t.Helper()
sendJSON(t, conn, SignalingMessage{
Type:     "register",
CircleID: circleID,
DeviceID: deviceID,
})
// Allow the server goroutine to process the registration.
time.Sleep(100 * time.Millisecond)
}

func TestRegisterDevice(t *testing.T) {
srv, hub := newTestServer(t)
conn := dialWS(t, srv)
register(t, conn, "circle1", "dev1")

if hub.manager.DeviceCount() != 1 {
t.Fatalf("expected 1 device, got %d", hub.manager.DeviceCount())
}
}

func TestRegisterMissingFields(t *testing.T) {
srv, _ := newTestServer(t)
conn := dialWS(t, srv)

sendJSON(t, conn, SignalingMessage{Type: "register", DeviceID: "d1"})
msg := readJSON(t, conn)
if msg.Type != "error" {
t.Fatalf("expected error, got %s", msg.Type)
}
}

func TestCallOfferToNonExistentDevice(t *testing.T) {
srv, _ := newTestServer(t)
conn := dialWS(t, srv)
register(t, conn, "circle1", "dev1")

sendJSON(t, conn, SignalingMessage{
Type:           "call_offer",
CallID:         "550e8400-e29b-41d4-a716-446655440000",
TargetDeviceID: "no-such-device",
})

msg := readJSON(t, conn)
if msg.Type != "error" {
t.Fatalf("expected error, got %s", msg.Type)
}
if msg.Message != "target device not connected" {
t.Fatalf("unexpected error message: %s", msg.Message)
}
}

func TestCallOfferWithoutRegister(t *testing.T) {
srv, _ := newTestServer(t)
conn := dialWS(t, srv)

sendJSON(t, conn, SignalingMessage{
Type:           "call_offer",
CallID:         "550e8400-e29b-41d4-a716-446655440000",
TargetDeviceID: "dev2",
})

msg := readJSON(t, conn)
if msg.Type != "error" {
t.Fatalf("expected error, got %s", msg.Type)
}
if msg.Message != "must register before making calls" {
t.Fatalf("unexpected error message: %s", msg.Message)
}
}

func TestFullCallFlow(t *testing.T) {
srv, hub := newTestServer(t)
callID := "550e8400-e29b-41d4-a716-446655440000"

conn1 := dialWS(t, srv)
conn2 := dialWS(t, srv)

register(t, conn1, "circle1", "dev1")
register(t, conn2, "circle1", "dev2")

// dev1 sends call_offer to dev2
sendJSON(t, conn1, SignalingMessage{
Type:           "call_offer",
CallID:         callID,
TargetDeviceID: "dev2",
SDP:            "offer-sdp-data",
})

// dev2 receives the offer
offer := readJSON(t, conn2)
if offer.Type != "call_offer" {
t.Fatalf("expected call_offer, got %s", offer.Type)
}
if offer.CallID != callID {
t.Fatalf("expected call_id %s, got %s", callID, offer.CallID)
}
if offer.CallerDeviceID != "dev1" {
t.Fatalf("expected caller_device_id dev1, got %s", offer.CallerDeviceID)
}
if offer.SDP != "offer-sdp-data" {
t.Fatalf("expected SDP offer-sdp-data, got %s", offer.SDP)
}

// dev1 receives call_ringing
ringing := readJSON(t, conn1)
if ringing.Type != "call_ringing" {
t.Fatalf("expected call_ringing, got %s", ringing.Type)
}
if ringing.CallID != callID {
t.Fatalf("expected call_id %s, got %s", callID, ringing.CallID)
}

// Verify session is in ringing state
if hub.manager.SessionCount() != 1 {
t.Fatalf("expected 1 session, got %d", hub.manager.SessionCount())
}

// dev2 answers the call
sendJSON(t, conn2, SignalingMessage{
Type:   "call_answer",
CallID: callID,
SDP:    "answer-sdp-data",
})

// dev1 receives the answer
answer := readJSON(t, conn1)
if answer.Type != "call_answer" {
t.Fatalf("expected call_answer, got %s", answer.Type)
}
if answer.SDP != "answer-sdp-data" {
t.Fatalf("expected SDP answer-sdp-data, got %s", answer.SDP)
}

	// Verify session is active
	state, ok := hub.manager.GetSessionState(callID)
	if !ok {
		t.Fatal("session not found")
	}
	if state != session.StateActive {
		t.Fatalf("expected active state, got %s", state)
	}
}

func TestBinaryFrameRouting(t *testing.T) {
srv, _ := newTestServer(t)
callID := "550e8400-e29b-41d4-a716-446655440000"

conn1 := dialWS(t, srv)
conn2 := dialWS(t, srv)

register(t, conn1, "circle1", "dev1")
register(t, conn2, "circle1", "dev2")

// Establish call
sendJSON(t, conn1, SignalingMessage{
Type:           "call_offer",
CallID:         callID,
TargetDeviceID: "dev2",
SDP:            "offer",
})
readJSON(t, conn2) // offer
readJSON(t, conn1) // ringing

sendJSON(t, conn2, SignalingMessage{
Type:   "call_answer",
CallID: callID,
SDP:    "answer",
})
readJSON(t, conn1) // answer

// Send binary audio frame from dev1 -> dev2
audioPayload := []byte("encrypted-audio-frame-content")
frame := make([]byte, 36+len(audioPayload))
copy(frame[:36], callID)
copy(frame[36:], audioPayload)

ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()
if err := conn1.Write(ctx, websocket.MessageBinary, frame); err != nil {
t.Fatalf("write binary: %v", err)
}

// dev2 receives the binary frame
msgType, received, err := conn2.Read(ctx)
if err != nil {
t.Fatalf("read binary: %v", err)
}
if msgType != websocket.MessageBinary {
t.Fatalf("expected binary message, got %d", msgType)
}
if string(received) != string(frame) {
t.Fatalf("binary frame mismatch:\ngot  %q\nwant %q", received, frame)
}

// Send binary audio frame from dev2 -> dev1
frame2 := make([]byte, 36+len(audioPayload))
copy(frame2[:36], callID)
copy(frame2[36:], []byte("response-audio-frame-content"))

if err := conn2.Write(ctx, websocket.MessageBinary, frame2); err != nil {
t.Fatalf("write binary: %v", err)
}

msgType, received2, err := conn1.Read(ctx)
if err != nil {
t.Fatalf("read binary: %v", err)
}
if msgType != websocket.MessageBinary {
t.Fatalf("expected binary message, got %d", msgType)
}
if string(received2) != string(frame2) {
t.Fatalf("binary frame mismatch:\ngot  %q\nwant %q", received2, frame2)
}
}

func TestCallEnd(t *testing.T) {
srv, hub := newTestServer(t)
callID := "550e8400-e29b-41d4-a716-446655440000"

conn1 := dialWS(t, srv)
conn2 := dialWS(t, srv)

register(t, conn1, "circle1", "dev1")
register(t, conn2, "circle1", "dev2")

// Establish call
sendJSON(t, conn1, SignalingMessage{
Type:           "call_offer",
CallID:         callID,
TargetDeviceID: "dev2",
SDP:            "offer",
})
readJSON(t, conn2) // offer
readJSON(t, conn1) // ringing

sendJSON(t, conn2, SignalingMessage{
Type:   "call_answer",
CallID: callID,
SDP:    "answer",
})
readJSON(t, conn1) // answer

// dev1 ends the call
sendJSON(t, conn1, SignalingMessage{
Type:   "call_end",
CallID: callID,
Reason: "user_hangup",
})

// dev2 receives call_end
endMsg := readJSON(t, conn2)
if endMsg.Type != "call_end" {
t.Fatalf("expected call_end, got %s", endMsg.Type)
}
if endMsg.Reason != "user_hangup" {
t.Fatalf("expected reason user_hangup, got %s", endMsg.Reason)
}

// Session should be removed
time.Sleep(50 * time.Millisecond)
if hub.manager.SessionCount() != 0 {
t.Fatalf("expected 0 sessions, got %d", hub.manager.SessionCount())
}
}

func TestDisconnectEndsSessions(t *testing.T) {
srv, hub := newTestServer(t)
callID := "550e8400-e29b-41d4-a716-446655440000"

conn1 := dialWS(t, srv)
conn2 := dialWS(t, srv)

register(t, conn1, "circle1", "dev1")
register(t, conn2, "circle1", "dev2")

// Establish call
sendJSON(t, conn1, SignalingMessage{
Type:           "call_offer",
CallID:         callID,
TargetDeviceID: "dev2",
SDP:            "offer",
})
readJSON(t, conn2) // offer
readJSON(t, conn1) // ringing

sendJSON(t, conn2, SignalingMessage{
Type:   "call_answer",
CallID: callID,
SDP:    "answer",
})
readJSON(t, conn1) // answer

// dev1 disconnects
conn1.Close(websocket.StatusNormalClosure, "bye")
time.Sleep(200 * time.Millisecond)

// Session should be cleaned up
if hub.manager.SessionCount() != 0 {
t.Fatalf("expected 0 sessions after disconnect, got %d", hub.manager.SessionCount())
}

// dev2 should receive call_end with peer_disconnected reason
msg := readJSON(t, conn2)
if msg.Type != "call_end" {
t.Fatalf("expected call_end, got %s", msg.Type)
}
if msg.Reason != "peer_disconnected" {
t.Fatalf("expected reason peer_disconnected, got %s", msg.Reason)
}
}

func TestUnknownMessageType(t *testing.T) {
srv, _ := newTestServer(t)
conn := dialWS(t, srv)
register(t, conn, "circle1", "dev1")

sendJSON(t, conn, SignalingMessage{Type: "bogus"})
msg := readJSON(t, conn)
if msg.Type != "error" {
t.Fatalf("expected error, got %s", msg.Type)
}
if msg.Message != "unknown message type" {
t.Fatalf("unexpected error: %s", msg.Message)
}
}

func TestSessionAutoCleanup(t *testing.T) {
mgr := session.NewManager()
hub := NewHub(mgr)

// Create a session and make it look idle
s := mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)
s.LastActivity = time.Now().Add(-2 * time.Minute)

expired := hub.manager.CleanupExpired(60*time.Second, time.Hour)
if len(expired) != 1 {
t.Fatalf("expected 1 expired session, got %d", len(expired))
}
if mgr.SessionCount() != 0 {
t.Fatalf("expected 0 sessions after cleanup, got %d", mgr.SessionCount())
}
}
