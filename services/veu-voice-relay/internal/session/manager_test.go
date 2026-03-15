package session

import (
"testing"
"time"
)

func TestRegisterAndUnregisterDevice(t *testing.T) {
mgr := NewManager()

mgr.RegisterDevice("c1:d1", nil)
mgr.RegisterDevice("c1:d2", nil)
if mgr.DeviceCount() != 2 {
t.Fatalf("expected 2 devices, got %d", mgr.DeviceCount())
}

mgr.UnregisterDevice("c1:d1")
if mgr.DeviceCount() != 1 {
t.Fatalf("expected 1 device, got %d", mgr.DeviceCount())
}

mgr.UnregisterDevice("c1:d2")
if mgr.DeviceCount() != 0 {
t.Fatalf("expected 0 devices, got %d", mgr.DeviceCount())
}
}

func TestGetDeviceConn(t *testing.T) {
mgr := NewManager()

_, ok := mgr.GetDeviceConn("c1:d1")
if ok {
t.Fatal("expected not found for unregistered device")
}

mgr.RegisterDevice("c1:d1", nil)
_, ok = mgr.GetDeviceConn("c1:d1")
if !ok {
t.Fatal("expected found for registered device")
}
}

func TestCreateSession(t *testing.T) {
mgr := NewManager()

s := mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)
if s.CallID != "call-1" {
t.Fatalf("expected call-1, got %s", s.CallID)
}
if s.State != StateOffering {
t.Fatalf("expected offering state, got %s", s.State)
}
if mgr.SessionCount() != 1 {
t.Fatalf("expected 1 session, got %d", mgr.SessionCount())
}
}

func TestSetSessionRinging(t *testing.T) {
mgr := NewManager()
mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)

if !mgr.SetSessionRinging("call-1") {
t.Fatal("expected SetSessionRinging to succeed")
}

s, ok := mgr.GetSession("call-1")
if !ok {
t.Fatal("session not found")
}
if s.State != StateRinging {
t.Fatalf("expected ringing, got %s", s.State)
}

// Cannot set ringing again
if mgr.SetSessionRinging("call-1") {
t.Fatal("expected SetSessionRinging to fail for ringing session")
}

// Non-existent session
if mgr.SetSessionRinging("no-such-call") {
t.Fatal("expected SetSessionRinging to fail for non-existent session")
}
}

func TestActivateSession(t *testing.T) {
mgr := NewManager()
mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)

s, ok := mgr.ActivateSession("call-1", nil)
if !ok {
t.Fatal("expected ActivateSession to succeed")
}
if s.State != StateActive {
t.Fatalf("expected active, got %s", s.State)
}

// Cannot activate again
_, ok = mgr.ActivateSession("call-1", nil)
if ok {
t.Fatal("expected ActivateSession to fail for already active session")
}

// Non-existent session
_, ok = mgr.ActivateSession("no-such-call", nil)
if ok {
t.Fatal("expected ActivateSession to fail for non-existent session")
}
}

func TestActivateFromRinging(t *testing.T) {
mgr := NewManager()
mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)
mgr.SetSessionRinging("call-1")

s, ok := mgr.ActivateSession("call-1", nil)
if !ok {
t.Fatal("expected ActivateSession to succeed from ringing")
}
if s.State != StateActive {
t.Fatalf("expected active, got %s", s.State)
}
}

func TestEndSession(t *testing.T) {
mgr := NewManager()
mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)
mgr.ActivateSession("call-1", nil)

s, ok := mgr.EndSession("call-1")
if !ok {
t.Fatal("expected EndSession to succeed")
}
if s.State != StateEnded {
t.Fatalf("expected ended, got %s", s.State)
}
if mgr.SessionCount() != 0 {
t.Fatalf("expected 0 sessions, got %d", mgr.SessionCount())
}

// Ending again should fail
_, ok = mgr.EndSession("call-1")
if ok {
t.Fatal("expected EndSession to fail for already ended session")
}
}

func TestGetPeerConn(t *testing.T) {
mgr := NewManager()

// Non-existent call
_, ok := mgr.GetPeerConn("no-call", "c1:d1")
if ok {
t.Fatal("expected GetPeerConn to fail for non-existent call")
}

// Offering state (not active)
mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)
_, ok = mgr.GetPeerConn("call-1", "c1:d1")
if ok {
t.Fatal("expected GetPeerConn to fail for non-active session")
}

// Active state with nil conns
mgr.ActivateSession("call-1", nil)
_, ok = mgr.GetPeerConn("call-1", "c1:d1")
if ok {
t.Fatal("expected GetPeerConn to return false when peer conn is nil")
}

// Non-participant
_, ok = mgr.GetPeerConn("call-1", "c1:d3")
if ok {
t.Fatal("expected GetPeerConn to fail for non-participant")
}
}

func TestTouchSession(t *testing.T) {
mgr := NewManager()
s := mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)
original := s.LastActivity

time.Sleep(10 * time.Millisecond)
mgr.TouchSession("call-1")

s, _ = mgr.GetSession("call-1")
if !s.LastActivity.After(original) {
t.Fatal("expected LastActivity to be updated")
}

// Touch non-existent session should not panic
mgr.TouchSession("no-such-call")
}

func TestEndSessionsForDevice(t *testing.T) {
mgr := NewManager()
mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)
mgr.CreateSession("call-2", "c1:d1", "c1:d3", nil)
mgr.CreateSession("call-3", "c1:d3", "c1:d4", nil)

ended := mgr.EndSessionsForDevice("c1:d1")
if len(ended) != 2 {
t.Fatalf("expected 2 ended sessions, got %d", len(ended))
}
if mgr.SessionCount() != 1 {
t.Fatalf("expected 1 remaining session, got %d", mgr.SessionCount())
}
}

func TestCleanupExpiredIdleTimeout(t *testing.T) {
mgr := NewManager()
s := mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)

// Simulate idle: set LastActivity to 2 minutes ago
s.LastActivity = time.Now().Add(-2 * time.Minute)

expired := mgr.CleanupExpired(60*time.Second, time.Hour)
if len(expired) != 1 {
t.Fatalf("expected 1 expired, got %d", len(expired))
}
if expired[0].CallID != "call-1" {
t.Fatalf("expected call-1, got %s", expired[0].CallID)
}
if mgr.SessionCount() != 0 {
t.Fatalf("expected 0 sessions, got %d", mgr.SessionCount())
}
}

func TestCleanupExpiredMaxDuration(t *testing.T) {
mgr := NewManager()
s := mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)

// Simulate max duration: set CreatedAt to 2 hours ago, but LastActivity recent
s.CreatedAt = time.Now().Add(-2 * time.Hour)
s.LastActivity = time.Now()

expired := mgr.CleanupExpired(60*time.Second, time.Hour)
if len(expired) != 1 {
t.Fatalf("expected 1 expired, got %d", len(expired))
}
if mgr.SessionCount() != 0 {
t.Fatalf("expected 0 sessions, got %d", mgr.SessionCount())
}
}

func TestCleanupKeepsActiveSessions(t *testing.T) {
mgr := NewManager()
mgr.CreateSession("call-1", "c1:d1", "c1:d2", nil)

expired := mgr.CleanupExpired(60*time.Second, time.Hour)
if len(expired) != 0 {
t.Fatalf("expected 0 expired, got %d", len(expired))
}
if mgr.SessionCount() != 1 {
t.Fatalf("expected 1 session, got %d", mgr.SessionCount())
}
}

func TestCallStateString(t *testing.T) {
tests := []struct {
state CallState
want  string
}{
{StateOffering, "offering"},
{StateRinging, "ringing"},
{StateActive, "active"},
{StateEnded, "ended"},
{CallState(99), "unknown"},
}
for _, tt := range tests {
if got := tt.state.String(); got != tt.want {
t.Errorf("CallState(%d).String() = %q, want %q", tt.state, got, tt.want)
}
}
}
