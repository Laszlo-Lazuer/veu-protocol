# VeuMesh — Multi-Transport Mesh Architecture

## Overview

VeuMesh provides always-on, iMessage-like sync for the Veu Protocol by layering three independent transports over the existing Ghost Network sync engine. All relay nodes remain completely blind — they store only encrypted ciphertext.

## Transport Priority

```
1. Local  (LAN/mDNS)         — lowest latency, same Wi-Fi / AWDL
2. Mesh   (Bluetooth LE+AWDL) — no Wi-Fi required, up to ~100m, multi-hop
3. Global (WebSocket relay)   — internet-wide, store-and-forward
```

All three use the same SyncEngine (vector clock delta-sync) and GhostMessage protocol. MeshNode tries all available transports simultaneously and prioritizes the fastest/closest.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                   App Layer                       │
│           NetworkService → MeshNode               │
└──────────────────────┬───────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────┐
│                   VeuMesh                         │
│  ┌──────────────┐ ┌──────────┐ ┌───────────────┐ │
│  │LocalTransport│ │  Mesh    │ │   Global      │ │
│  │(wraps        │ │Transport │ │  Transport    │ │
│  │ LocalPulse)  │ │(BT+AWDL) │ │(WS relay)    │ │
│  └──────────────┘ └──────────┘ └───────────────┘ │
│  MeshNode (coordinator + transport lifecycle)     │
└──────────────────────┬───────────────────────────┘
                       │ acceptConnection()
┌──────────────────────▼───────────────────────────┐
│              VeuGhost (unchanged)                 │
│  TransportConnection protocol                     │
│  SyncEngine + VectorClock (delta-sync)            │
│  GhostNode (transport-agnostic)                   │
└──────────────────────────────────────────────────┘
```

## Protocols

### TransportConnection (veu-ghost)

The fundamental connection interface. All transport implementations produce connections conforming to this protocol:

```swift
public protocol TransportConnection: AnyObject {
    var endpointDescription: String { get }
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Result<Data, Error>) -> Void)
    func cancel()
}
```

### MeshTransportProtocol (veu-mesh)

Higher-level transport interface with lifecycle and state management:

```swift
public protocol MeshTransportProtocol: AnyObject {
    var name: String { get }
    var state: MeshTransportState { get }
    var isAvailable: Bool { get }
    var delegate: MeshTransportDelegate? { get set }
    func start() throws
    func stop()
}
```

### MeshTransportDelegate

```swift
public protocol MeshTransportDelegate: AnyObject {
    func transport(_ transport: any MeshTransportProtocol, didChangeState: MeshTransportState)
    func transport(_ transport: any MeshTransportProtocol, didConnectPeer: any TransportConnection)
    func transport(_ transport: any MeshTransportProtocol, didDisconnectPeer peerID: String)
}
```

## Transport Details

### LocalTransport

Wraps the existing `LocalPulse` (mDNS/Bonjour) discovery and `GhostConnection` (TCP) transport from veu-ghost. This is the highest priority transport — lowest latency on the same Wi-Fi network.

### MeshTransport (Bluetooth LE + AWDL)

Uses Apple's MultipeerConnectivity framework for Bluetooth LE and AWDL peer discovery. Key features:

- **Service type**: `veu-mesh` (15-char limit for MC)
- **Discovery info**: Topic hash prefix (16 chars) for circle-scoped discovery
- **Session encryption**: `.required` (MCSession built-in encryption)
- **Multi-hop relay**: Messages can traverse up to 5 intermediate peers
- **Routing table**: `MeshRouter` tracks peer → hop-count mappings
- **MeshEnvelope**: Wraps messages with TTL countdown, source/destination IDs

```swift
struct MeshEnvelope: Codable {
    let source: String        // originating device ID
    let destination: String   // target device ID (or "*" for broadcast)
    let ttl: Int              // decremented at each hop, max 5
    let payload: Data         // encrypted GhostMessage envelope
}
```

### GlobalTransport (WebSocket Relay)

Connects to a self-hosted relay server over WebSocket for internet-wide sync:

- **Authentication**: Circle topic hash (HMAC-SHA-256) — relay cannot derive the circle key
- **Wire protocol**: JSON messages over WebSocket (see `RelayMessage` enum)
- **Auto-reconnect**: Exponential backoff on disconnect
- **Store-and-forward**: Relay stores encrypted blobs; peers pull on reconnect
- **APNs integration**: Silent push to wake offline peers

#### Relay Wire Protocol

```swift
enum RelayMessage: Codable {
    case subscribe(topicHash: String, deviceID: String)
    case publish(topicHash: String, cid: String, blob: Data)
    case deliver(cid: String, blob: Data, from: String)
    case pull(topicHash: String, since: TimeInterval)
    case pullResponse(artifacts: [(cid: String, blob: Data)])
    case registerPush(token: String)
    case ack(cid: String)
}
```

## CIDv1 Content Addressing

All artifacts are identified by IPFS-compatible CIDv1 content identifiers:

```
Format: b + base32lower(0x01 + 0x55 + 0x12 + 0x20 + SHA-256(data))
         │              │      │      │      │
         │              │      │      │      └─ digest length (32 bytes)
         │              │      │      └─ SHA-256 multicodec
         │              │      └─ raw multicodec
         │              └─ CIDv1 version
         └─ base32lower multibase prefix

Example: bafkreihdwdcefg...
```

This is future-compatible with full IPFS integration — the same CID can be used to fetch artifacts from IPFS nodes.

## Relay Server

The `veu-relay` Go server is a blind store-and-forward node:

- **Stores**: `(cid, topic_hash, encrypted_blob, timestamp)` — no plaintext ever
- **Channels**: Circle-scoped WebSocket channels identified by topic hash
- **Push**: Optional APNs silent push for offline peer wake-up
- **Self-hosted**: Docker Compose ready, single binary, SQLite storage

See `services/veu-relay/RELAY.md` for deployment documentation.

## Background Sync

iOS background sync uses a multi-layer approach:

1. **BGAppRefreshTask** (`com.veu.protocol.sync.refresh`): Lightweight delta check, system-scheduled (~15 min intervals)
2. **BGProcessingTask** (`com.veu.protocol.sync.processing`): Full sync when on Wi-Fi + charging
3. **APNs Silent Push**: Relay sends silent push to wake the app when artifacts arrive for offline peers

## Security Model

- All transports carry the same AES-256-GCM encrypted GhostMessage envelopes
- Relay nodes are completely blind — they never see plaintext or circle keys
- MultipeerConnectivity sessions use `.required` encryption
- Topic hashes are HMAC-SHA-256 derived — relay cannot compute them without the circle key
- Push tokens are stored only on the user's self-hosted relay
- CIDv1 is content-addressed — artifacts are globally unique and tamper-evident
