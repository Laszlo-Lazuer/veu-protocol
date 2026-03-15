# veu-voice-relay

Real-time encrypted voice relay for the VEU protocol. Acts as an audio bridge between two call participants — forwarding encrypted audio frames without decryption, storage, or transcoding.

## Architecture

```
┌──────────┐          ┌────────────────┐          ┌──────────┐
│ Device A │◄────────►│ veu-voice-relay │◄────────►│ Device B │
│ (caller) │  WebSocket│   (pure pipe)  │WebSocket  │ (callee) │
└──────────┘          └────────────────┘          └──────────┘
```

- **No storage** — audio frames are never persisted
- **No decryption** — the relay sees only AES-256-GCM ciphertext
- **No transcoding** — frames are forwarded byte-for-byte

### Transport Priority

The voice relay is a **fallback**, not the default. Audio transport follows the same priority as messaging:

| Priority | Transport | When Used |
|----------|-----------|-----------|
| 1st | **UDP (direct)** | Peers on same LAN/WiFi |
| 2nd | **Voice Relay (WebSocket)** | Peers on different networks, behind NAT |
| 3rd | **TCP mesh** | Last resort fallback |

Signaling always goes through GhostMessage (Local → Mesh → Global relay).
The voice relay handles only audio frame forwarding.

### Network Transition

Mid-call WiFi ↔ cellular handoffs are handled automatically:
- **WiFi → cellular**: UDP drops, relay takes over seamlessly
- **cellular → WiFi**: Attempts UDP reconnect, upgrades if peer is reachable
- **Network loss**: Audio paused, resumes on reconnect

## Authentication

Registration requires an Ed25519-signed token proving device identity:

```json
{
  "type": "register",
  "device_id": "a1b2c3d4e5f67890",
  "circle_id": "circle_uuid",
  "public_key": "hex-encoded Ed25519 public key",
  "timestamp": "1710000000",
  "signature": "hex-encoded Ed25519 signature"
}
```

**Verification steps:**
1. Derive `device_id` from `SHA-256(public_key)[:8]` and verify match
2. Validate Ed25519 signature over `device_id|circle_id|timestamp`
3. Check timestamp freshness (within 30 seconds)
4. Reject replayed signatures (nonce cache with 60s TTL)

## Rate Limiting

Per-connection token bucket:

| Traffic | Sustained | Burst | Excess |
|---------|-----------|-------|--------|
| Signaling | 10 msg/s | 20 burst | Error returned |
| Audio | 100 frames/s | 150 burst | Silently dropped |

## Wire Protocol

All communication happens over a single WebSocket connection at `GET /ws`.

### Signaling Messages (JSON text frames)

| Direction | Type | Fields | Description |
|-----------|------|--------|-------------|
| C → R | `register` | `device_id`, `circle_id`, `public_key`, `timestamp`, `signature`, `push_token` | Register with Ed25519 auth + optional VoIP push token |
| C → R | `call_offer` | `call_id`, `target_device_id`, `sdp` | Initiate call to peer |
| R → C | `call_offer` | `call_id`, `caller_device_id`, `sdp` | Forward offer to callee |
| R → C | `call_ringing` | `call_id` | Offer was delivered |
| R → C | `call_push_sent` | `call_id` | Target offline; VoIP push sent to wake callee |
| C → R | `call_answer` | `call_id`, `sdp` | Accept a call |
| R → C | `call_answer` | `call_id`, `sdp` | Forward answer to caller |
| C → R | `call_end` | `call_id`, `reason` | End a call |
| R → C | `call_end` | `call_id`, `reason` | Notify peer of call end |
| R → C | `error` | `message` | Error response |

### Binary Audio Frames (binary WebSocket frames)

```
┌──────────────────────────────────────────────────┐
│ call_id (36 bytes, UTF-8 UUID) │ encrypted audio │
└──────────────────────────────────────────────────┘
```

- First 36 bytes: call_id as UUID string (used for routing)
- Remaining bytes: AES-256-GCM encrypted Opus audio (opaque to relay)
- Maximum frame size: 64 KB
- Audio codec: Opus at 32kbps (~80-160 bytes/frame), with µ-law G.711 fallback

## Call Lifecycle

1. Both clients connect to `/ws` and send `register` with Ed25519-signed identity
2. Caller sends `call_offer` → relay forwards to callee, sends `call_ringing` to caller
3. Callee sends `call_answer` → relay forwards to caller, session becomes active
4. Both sides exchange binary audio frames → relay forwards to peer
5. Either side sends `call_end` → relay notifies peer, tears down session
6. If a peer disconnects, relay sends `call_end` with reason `peer_disconnected`

### Offline Callee (VoIP Push)

When the callee is not connected to the relay:

1. Caller sends `call_offer` → relay checks if target has a stored push token
2. Relay sends APNs VoIP push to wake callee → responds with `call_push_sent`
3. Callee's app wakes, connects to relay, sends `register`, then `call_answer`
4. Normal call flow continues

Push tokens are sent during `register` via the optional `push_token` field.
The relay uses Apple APNs HTTP/2 with JWT (ES256) authentication.

## Session Management

- Ringing sessions expire after **45 seconds** (no answer)
- Active sessions expire after **60 seconds** of no audio frames
- Hard limit of **1 hour** per call
- Cleanup runs every **15 seconds**
- Expired sessions trigger `call_end` with reason `session_expired`

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `VEU_VOICE_RELAY_PORT` | `8080` | HTTP listen port |
| `VEU_APNS_KEY_PATH` | — | Path to `.p8` APNs auth key |
| `VEU_APNS_KEY_ID` | — | 10-char APNs key ID |
| `VEU_APNS_TEAM_ID` | — | 10-char Apple Team ID |
| `VEU_APNS_BUNDLE_ID` | `com.squirrelyeye.veu` | App bundle ID |
| `VEU_APNS_SANDBOX` | `false` | Use sandbox APNs endpoint |

## Health Check

```
GET /health → {"status":"ok","version":"0.1.0"}
```

## Development

```bash
# Build
CGO_ENABLED=0 go build -o veu-voice-relay .

# Test (42 tests, race detector enabled)
CGO_ENABLED=0 go test ./... -race

# Run
./veu-voice-relay
```

## Deployment

Deployed on Fly.io:

```bash
fly apps create veu-voice-relay
fly deploy
```

See `fly.toml` for configuration. No persistent volumes needed.
