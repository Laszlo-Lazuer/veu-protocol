# Veu Relay Server

A blind store-and-forward relay for the Veu zero-trust encrypted messaging protocol.

## What the Relay Does

The relay is a **blind intermediary** — it stores and forwards encrypted artifacts between devices that are not on the same local network. It never holds Circle Keys, never decrypts payloads, and never sees plaintext. All artifacts are opaque encrypted blobs identified by content-addressed CIDs and routed via HMAC-SHA-256 topic hashes.

When a device pushes an encrypted artifact:

1. The relay persists it to SQLite for offline retrieval.
2. It broadcasts the artifact to any peers currently connected on the same topic.
3. It optionally sends an APNs silent push to wake offline devices.

## Prerequisites

- **Docker** (recommended), or
- **Go 1.22+** with CGO enabled (for SQLite)

## Quick Start with Docker

```bash
# Clone and enter the relay directory
cd services/veu-relay

# Start the relay
docker compose up -d

# Verify it's running
curl http://localhost:8080/health
# → {"status":"ok","version":"0.1.0"}
```

## Build from Source

```bash
cd services/veu-relay

# Install dependencies
go mod tidy

# Build (CGO required for SQLite)
CGO_ENABLED=1 go build -o veu-relay .

# Run
./veu-relay
```

## Deploy to Fly.io (Recommended)

The relay runs on Fly.io's free tier (1 shared VM + 1 GB persistent volume).

```bash
# Install Fly CLI
brew install flyctl

# Authenticate
fly auth login

# Deploy from the relay directory
cd services/veu-relay
fly launch --copy-config --yes

# Create persistent volume for SQLite
fly volumes create veu_data --region iad --size 1

# Deploy
fly deploy

# Verify
curl https://veu-relay.fly.dev/health
# → {"status":"ok","version":"0.1.0"}
```

Connect from the app using relay URL: `wss://veu-relay.fly.dev/ws`

To add APNs push support later:
```bash
fly secrets set VEU_APNS_KEY_PATH=/data/apns-key.p8
fly secrets set VEU_APNS_KEY_ID=YOUR_KEY_ID
fly secrets set VEU_APNS_TEAM_ID=YOUR_TEAM_ID
fly secrets set VEU_APNS_TOPIC=com.veu.app
```

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|---|---|---|
| `VEU_RELAY_PORT` | `8080` | HTTP listen port |
| `VEU_RELAY_DB_PATH` | `./veu-relay.db` | Path to the SQLite database file |
| `VEU_APNS_KEY_PATH` | *(none)* | Path to APNs `.p8` key file |
| `VEU_APNS_KEY_ID` | *(none)* | APNs key ID |
| `VEU_APNS_TEAM_ID` | *(none)* | Apple Developer Team ID |
| `VEU_APNS_TOPIC` | *(none)* | APNs topic (bundle ID, e.g. `com.veu.app`) |

## APNs Setup (Optional)

To enable silent push notifications for waking offline devices:

1. Create an APNs key in the [Apple Developer Portal](https://developer.apple.com/account/resources/authkeys/list).
2. Download the `.p8` key file.
3. Set the four `VEU_APNS_*` environment variables.

If any APNs variable is missing, push notifications are silently disabled — the relay will still function for online WebSocket clients.

## Wire Protocol

Clients communicate over WebSocket at `/ws?topic=<64-char-hex-topic-hash>`:

```jsonc
// Client → Relay: push an encrypted artifact
{"type": "artifact_push", "cid": "<cidv1>", "topic": "<hex>", "payload": "<base64>", "persist": true}

// Client → Relay: pull artifacts since a timestamp
{"type": "pull_request", "topic": "<hex>", "since": 1709000000}

// Relay → Client: pull response
{"type": "pull_response", "artifacts": [{"cid": "...", "payload": "...", "timestamp": 1709001000}]}

// Relay → Client: sender-visible acknowledgement for artifact_push
{"type": "artifact_ack", "cid": "<cidv1-or-relay-message-id>", "topic": "<hex>", "status": "accepted|duplicate|rejected", "message": "artifact stored"}

// Client → Relay: register push token
{"type": "register_token", "topic": "<hex>", "token": "<hex>", "device_id": "<uuid>"}

// Relay → Client: new artifact broadcast
{"type": "artifact_notify", "cid": "<cidv1>", "topic": "<hex>", "payload": "<base64>"}
```

## Security Considerations

- **The relay is blind.** It only ever sees encrypted ciphertext and topic hashes. It cannot decrypt artifacts, identify users, or read message content.
- **Topic hashes are opaque.** They are HMAC-SHA-256 digests derived from Circle Keys that the relay never possesses.
- **No authentication on the relay itself.** Knowledge of a topic hash is the capability that grants access. This is by design — the relay cannot distinguish legitimate participants from others who know the hash.
- **TLS is expected.** Always deploy behind a TLS-terminating reverse proxy or load balancer in production.
- **SQLite WAL mode** is enabled for concurrent read/write performance.
- **Artifact deduplication** is enforced via unique CID constraints — replaying the same artifact is a no-op.
- **Message limits:** Maximum WebSocket message size is 10 MB; maximum artifact payload is 5 MB.
- **Delivery acknowledgement:** The relay now explicitly confirms whether each `artifact_push` was accepted, rejected, or treated as a duplicate so clients can surface sender-visible delivery status.

## Recommended Fly.io production settings for MVP

For the current MVP footprint, prefer a single always-on machine in `dfw`:

- `primary_region = "dfw"` for a better midpoint between Denver and Texas testers.
- `auto_stop_machines = "off"` to avoid cold-start delays on websocket reconnects and timeline posting.
- `kill_signal = "SIGTERM"` and a longer `kill_timeout` so websocket clients have a better chance to drain cleanly during deploys.
- `idle_timeout = 600` to reduce accidental websocket idle disconnects at the proxy layer.
- A small pinned VM (`shared-cpu-1x`, `512mb`) for predictable runtime characteristics at low monthly cost.
- Volume snapshot retention for basic recovery if the single SQLite volume needs to be restored.
