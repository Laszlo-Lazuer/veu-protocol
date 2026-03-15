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

## Wire Protocol

All communication happens over a single WebSocket connection at `GET /ws`.

### Signaling Messages (JSON text frames)

| Direction | Type | Fields | Description |
|-----------|------|--------|-------------|
| C → R | `register` | `device_id`, `circle_id` | Register identity for this connection |
| C → R | `call_offer` | `call_id`, `target_device_id`, `sdp` | Initiate call to peer |
| R → C | `call_offer` | `call_id`, `caller_device_id`, `sdp` | Forward offer to callee |
| R → C | `call_ringing` | `call_id` | Offer was delivered |
| C → R | `call_answer` | `call_id`, `sdp` | Accept a call |
| R → C | `call_answer` | `call_id`, `sdp` | Forward answer to caller |
| C → R | `call_end` | `call_id`, `reason` | End a call |
| R → C | `call_end` | `call_id`, `reason` | Notify peer of call end |
| C → R | `ice_candidate` | `call_id`, `candidate` | ICE candidate (future) |
| R → C | `error` | `message` | Error response |

### Binary Audio Frames (binary WebSocket frames)

```
┌──────────────────────────────────────────────────┐
│ call_id (36 bytes, UTF-8 UUID) │ encrypted audio │
└──────────────────────────────────────────────────┘
```

- First 36 bytes: call_id as UUID string (used for routing)
- Remaining bytes: AES-256-GCM encrypted audio (opaque to relay)
- Maximum frame size: 64 KB

## Call Lifecycle

1. Both clients connect to `/ws` and send `register` with `device_id` and `circle_id`
2. Caller sends `call_offer` → relay forwards to callee, sends `call_ringing` to caller
3. Callee sends `call_answer` → relay forwards to caller, session becomes active
4. Both sides exchange binary audio frames → relay forwards to peer
5. Either side sends `call_end` → relay notifies peer, tears down session
6. If a peer disconnects, relay sends `call_end` with reason `peer_disconnected`

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

## Health Check

```
GET /health → {"status":"ok","version":"0.1.0"}
```

## Development

```bash
# Build
CGO_ENABLED=0 go build -o veu-voice-relay .

# Test
CGO_ENABLED=0 go test ./... -race

# Run
./veu-voice-relay
```

## Deployment

Deployed on Fly.io:

```bash
fly deploy
```

See `fly.toml` for configuration. No persistent volumes needed.
