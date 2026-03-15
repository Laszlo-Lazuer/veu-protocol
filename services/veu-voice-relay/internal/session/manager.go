package session

import (
"log/slog"
"sync"
"time"

"nhooyr.io/websocket"
)

// CallState represents the lifecycle state of a voice call session.
type CallState int

const (
StateOffering CallState = iota
StateRinging
StateActive
StateEnded
)

func (s CallState) String() string {
switch s {
case StateOffering:
return "offering"
case StateRinging:
return "ringing"
case StateActive:
return "active"
case StateEnded:
return "ended"
default:
return "unknown"
}
}

// CallSession represents an active voice call between two devices.
type CallSession struct {
CallID       string
CallerKey    string // "circle_id:device_id"
CalleeKey    string // "circle_id:device_id"
CallerConn   *websocket.Conn
CalleeConn   *websocket.Conn
State        CallState
CreatedAt    time.Time
LastActivity time.Time
}

// Manager tracks registered devices and active call sessions.
type Manager struct {
mu       sync.RWMutex
devices  map[string]*websocket.Conn // "circle_id:device_id" → conn
sessions map[string]*CallSession    // call_id → session
}

func NewManager() *Manager {
return &Manager{
devices:  make(map[string]*websocket.Conn),
sessions: make(map[string]*CallSession),
}
}

func (m *Manager) RegisterDevice(key string, conn *websocket.Conn) {
m.mu.Lock()
defer m.mu.Unlock()
m.devices[key] = conn
}

func (m *Manager) UnregisterDevice(key string) {
m.mu.Lock()
defer m.mu.Unlock()
delete(m.devices, key)
}

func (m *Manager) GetDeviceConn(key string) (*websocket.Conn, bool) {
m.mu.RLock()
defer m.mu.RUnlock()
conn, ok := m.devices[key]
return conn, ok
}

func (m *Manager) DeviceCount() int {
m.mu.RLock()
defer m.mu.RUnlock()
return len(m.devices)
}

func (m *Manager) SessionCount() int {
m.mu.RLock()
defer m.mu.RUnlock()
return len(m.sessions)
}

func (m *Manager) CreateSession(callID, callerKey, calleeKey string, callerConn *websocket.Conn) *CallSession {
m.mu.Lock()
defer m.mu.Unlock()
now := time.Now()
s := &CallSession{
CallID:       callID,
CallerKey:    callerKey,
CalleeKey:    calleeKey,
CallerConn:   callerConn,
State:        StateOffering,
CreatedAt:    now,
LastActivity: now,
}
m.sessions[callID] = s
return s
}

func (m *Manager) SetSessionRinging(callID string) bool {
m.mu.Lock()
defer m.mu.Unlock()
s, ok := m.sessions[callID]
if !ok || s.State != StateOffering {
return false
}
s.State = StateRinging
return true
}

func (m *Manager) ActivateSession(callID string, calleeConn *websocket.Conn) (*CallSession, bool) {
m.mu.Lock()
defer m.mu.Unlock()
s, ok := m.sessions[callID]
if !ok || (s.State != StateOffering && s.State != StateRinging) {
return nil, false
}
s.CalleeConn = calleeConn
s.State = StateActive
s.LastActivity = time.Now()
return s, true
}

func (m *Manager) GetSession(callID string) (*CallSession, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[callID]
	return s, ok
}

// GetSessionState returns the state of a session under the manager lock.
func (m *Manager) GetSessionState(callID string) (CallState, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[callID]
	if !ok {
		return StateEnded, false
	}
	return s.State, true
}

func (m *Manager) EndSession(callID string) (*CallSession, bool) {
m.mu.Lock()
defer m.mu.Unlock()
s, ok := m.sessions[callID]
if !ok {
return nil, false
}
s.State = StateEnded
delete(m.sessions, callID)
return s, true
}

// GetPeerConn returns the WebSocket connection of the other participant in an
// active call. Returns nil if the session doesn't exist, is not active, or
// senderKey is not a participant.
func (m *Manager) GetPeerConn(callID, senderKey string) (*websocket.Conn, bool) {
m.mu.RLock()
defer m.mu.RUnlock()
s, ok := m.sessions[callID]
if !ok || s.State != StateActive {
return nil, false
}
if senderKey == s.CallerKey && s.CalleeConn != nil {
return s.CalleeConn, true
}
if senderKey == s.CalleeKey && s.CallerConn != nil {
return s.CallerConn, true
}
return nil, false
}

func (m *Manager) TouchSession(callID string) {
m.mu.Lock()
defer m.mu.Unlock()
if s, ok := m.sessions[callID]; ok {
s.LastActivity = time.Now()
}
}

// EndSessionsForDevice ends all sessions where the given device is a
// participant and returns the ended sessions so callers can notify peers.
func (m *Manager) EndSessionsForDevice(deviceKey string) []*CallSession {
m.mu.Lock()
defer m.mu.Unlock()
var ended []*CallSession
for id, s := range m.sessions {
if s.CallerKey == deviceKey || s.CalleeKey == deviceKey {
s.State = StateEnded
ended = append(ended, s)
delete(m.sessions, id)
}
}
return ended
}

// CleanupExpired removes sessions that have been idle longer than idleTimeout
// or have exceeded maxDuration. Returns removed sessions for notification.
func (m *Manager) CleanupExpired(idleTimeout, maxDuration time.Duration) []*CallSession {
m.mu.Lock()
defer m.mu.Unlock()
now := time.Now()
var expired []*CallSession
for id, s := range m.sessions {
idle := now.Sub(s.LastActivity) > idleTimeout
tooLong := now.Sub(s.CreatedAt) > maxDuration
if idle || tooLong {
s.State = StateEnded
expired = append(expired, s)
delete(m.sessions, id)
reason := "idle_timeout"
if tooLong {
reason = "max_duration"
}
slog.Info("session expired", "call_id", id, "reason", reason)
}
}
return expired
}
