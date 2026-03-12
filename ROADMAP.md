# Veu Protocol: Development Roadmap & "What's Next"

This document serves as the persistent context for the Veu protocol's development. As of **2026-03-10**, we are in active POC implementation.

## ✅ Completed Foundations

### Fortress Layer (Specs)
- **`veu-crypto`**: Emerald Handshake and artifact Burn/Purge specification.
- **`veu-auth`**: Hardware-bound security (App Attest) and Dead Link ephemeral invites.
- **`veu-protocol`**: The "Ghost Network" sync layer and Zero-Aware delta-sync.
- **`veu-app`**: The "Double Mirror" UX interaction and the Zero-Aware EULA.
- **The Aura Shader** (`packages/veu-app/AURA.glsl`): Animated, reactive identity Aura GLSL fragment shader seeded by the user's key hash.
- **The Local Artifact Ledger** (`packages/veu-protocol/LEDGER.sql`): SQLite schema for Zero-Aware, device-local artifact tracking with Burn/Purge and encrypted metadata.
- **The Emerald Handshake Visuals** (`packages/veu-crypto/EMERALD_HANDSHAKE.md`, `packages/veu-app/EMERALD.glsl`): Full spec and GLSL implementation of the 7-phase handshake ceremony.
- **Post-Quantum Hardening** (`packages/veu-crypto/POST_QUANTUM.md`): Migration strategy to ML-KEM-1024, ML-DSA-Dilithium-5, and SPHINCS+ with hybrid transition plan.

### POC Layer (Implementation)
- **Phase 1 — Crypto Core** (`packages/veu-crypto/`): Swift Package implementing AES-256-GCM scramble/unscramble, HMAC-SHA-256 Glaze Seed derivation, Circle Key + Artifact Key management, and Burn Engine. Fully unit tested (`swift test`).
- **Phase 2 — The Handshake** (`packages/veu-auth/`): Swift Package implementing Dead Link URI generation/parsing (Ed25519 signed), X25519 ECDH key exchange, HKDF-SHA-256 Circle key derivation, SAS 8-digit short-code + Aura color derivation, HandshakeSession orchestrator (7-phase state machine), and SQLite Ledger bootstrap (LEDGER.sql). 61 tests passing (`swift test`).
- **Phase 3 — The Glaze Engine** (`packages/veu-glaze/`): Swift Package implementing GLSL→Metal shader translation (AURA + EMERALD), MetalRenderer base pipeline with runtime MSL compilation, AuraView + EmeraldView SwiftUI wrappers, Vue Toggle (long-press → biometric → reveal) with session-based unlock, and HapticEngine (heartbeat/burn/hum). 34 tests passing (`swift test`).
- **Phase 4 — Ghost Network** (`packages/veu-ghost/`): Swift Package implementing mDNS/Bonjour peer discovery (LocalPulse), AES-256-GCM encrypted TCP transport (GhostConnection), vector clock delta-sync (SyncEngine), Codable protocol messages (SyncRequest/ArtifactPush/BurnNotice/Ack), and GhostNode coordinator. 44 tests passing (`swift test`).
- **Phase 6 — On-Device POC Demo** (`apps/VeuDemo/`): Xcode iOS app (generated via XcodeGen) wiring VeuApp into a real-device demo. QR code generation + camera scanner for Dead Link sharing, AVCapturePhotoOutput for photo capture, AppCoordinator `@ObservableObject` driving all state, 5-tab UI (Identity/Handshake/Chat/Timeline/Network). Builds for iOS 16+ with Local Network, Camera, and FaceID entitlements.

### Phase 2 — The Handshake (`veu-auth`) 🤝
> _Two devices perform a live Emerald Handshake — the core trust primitive._

- [x] Dead Link URI generation (`veu://handshake?pk=…&exp=…&sig=…`)
- [x] Curve25519 ECDH key exchange → Shared Secret derivation
- [x] SAS derivation: Shared Secret → 8-digit code + Aura color hex
- [x] Bootstrap `LEDGER.sql` SQLite schema into a Swift Package (`veu-auth`)
- [x] Minimal handshake UI: QR code display + 8-digit confirmation screen

### Phase 3 — The Glaze Engine (`veu-glaze` + `veu-app`) 🎨
> _Wire the GLSL shaders to real cryptographic data._

- [x] `AuraView` (SwiftUI + Metal): load `AURA.glsl`, feed `u_seed_color` from Glaze Seed
- [x] `EmeraldView`: load `EMERALD.glsl`, drive `u_phase` from handshake state machine
- [x] Vue Toggle: long-press → FaceID → shader opacity 0 → reveal artifact
- [x] `HapticEngine`: handshake heartbeat, burn click, vue hum

### Phase 4 — Ghost Network (minimal) 📡
> _Artifact sync between two devices with no central server._

- [x] Local Pulse: mDNS/Bonjour peer discovery on same Wi-Fi
- [x] Artifact publish: encrypt artifact → push to peer over local connection
- [x] Artifact Ledger sync: update `LEDGER.sql` on receive, drive UI
- [x] _Post-POC: IPFS + Tor integration_ → Phase 7: Global Mesh + Offline Relay

### Phase 7 — Global Mesh + Offline Relay (`veu-mesh`, `veu-relay`) 🌐
> _Always-on, iMessage-like sync across any network — LAN, Bluetooth mesh, and global relay._

- [x] Transport abstraction: `TransportConnection` + `DiscoveryService` protocols in `veu-ghost`
- [x] GhostNode refactored to accept any transport (transport-agnostic connections)
- [x] CIDv1 content addressing: SHA-256 → multihash → base32lower (IPFS-compatible)
- [x] `veu-mesh` package: multi-transport mesh coordinator
  - [x] `LocalTransport`: wraps existing LocalPulse (LAN/mDNS)
  - [x] `MeshTransport`: Bluetooth LE + AWDL with multi-hop relay (max 5 hops)
  - [x] `GlobalTransport`: WebSocket relay client with auto-reconnect
  - [x] `MeshNode`: top-level coordinator with transport priority (Local > Mesh > Global)
- [x] `veu-relay` Go server: blind store-and-forward relay
  - [x] WebSocket hub with circle-scoped topic channels
  - [x] SQLite store-and-forward (encrypted blobs only)
  - [x] APNs silent push integration
  - [x] Docker + self-hosting documentation
- [x] App integration: NetworkService → MeshNode, transport status UI
- [x] Background tasks: BGAppRefreshTask + BGProcessingTask + APNs silent push
- [x] Mesh network UI: transport indicator, relay URL configuration, peer status

### Phase 5 — POC Demo App (`veu-app`) 📱
> _Integration app wiring all packages into a runnable on-device demo._

- [x] Identity model: Ed25519 keypair generation, callsign derivation, Aura seed
- [x] AppState: central state manager for identity, circles, and Ledger
- [x] HandshakeViewModel: Dead Link → QR → short code → confirm → Circle key
- [x] TimelineViewModel: compose → encrypt → Ledger insert → Glaze seed colors
- [x] NetworkService: MeshNode lifecycle wrapper with multi-transport sync delegate bridging
- [x] SwiftUI views: HomeView, IdentityView, HandshakeView, TimelineView, ComposeView

### Phase 6 — On-Device POC Demo (`apps/VeuDemo`) 🚀
> _Installable iOS app exercising the full two-device demo on real hardware._

- [x] Xcode project (XcodeGen): bundle ID, signing, entitlements (Local Network, Camera, FaceID)
- [x] QR code generation: CoreImage `CIQRCodeGenerator` for Dead Link display
- [x] QR scanner: `AVCaptureMetadataOutput` to scan peer's Dead Link
- [x] Camera capture: `AVCapturePhotoOutput` for photo artifacts
- [x] AppCoordinator: centralized `@ObservableObject` driving all view state
- [x] 5-tab UI: Identity, Handshake, Chat, Timeline, Ghost Network

### Phase 8 — Timeline Redesign + Persistence + Bug Fixes 🔄
> _Instagram-style feed with FOMO-driven targeted visibility, persistent state, and camera bug fixes._

- [x] **Bug fixes**
  - [x] Camera permission: `AVCaptureDevice.requestAccess(for: .video)` before setup
  - [x] PhotoDelegate retention: stored as instance property to prevent deallocation
  - [x] Seal error surfacing: `@Published sealError` with `.alert()` in DemoRootView
  
- [x] **Persistence layer** (Keychain + SQLite)
  - [x] `KeychainService`: stores Identity + CircleKey with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  - [x] Persistent Ledger: SQLite file in Documents/ with `NSFileProtectionComplete`
  - [x] `AppState.bootstrap()`: restore identity/keys from Keychain, restore activeCircle from UserDefaults
  - [x] Circle keys backed by Keychain (persist on add, delete on remove)
  - [ ] Persistence unit tests (deferred to follow-up PR)
  
- [x] **Timeline feed redesign**
  - [x] Instagram-style full-width vertical scroll (~65% viewport height per card)
  - [x] Session-based unlock: FaceID once on launch → auto-reveal all content
  - [x] VueToggle session-aware mode: auto-reveal when `sessionUnlocked=true`
  - [x] FOMO skeleton: animated Aura + fake callsign for non-recipient targeted posts
  - [x] Mini-Aura avatar component for sender display
  - [x] Compose with recipient picker: select specific circle members for targeted posts
  
- [x] **Ledger schema v2** (artifacts + circle_members)
  - [x] `sender_id`, `target_recipients`, `wrapped_keys` columns in artifacts
  - [x] `circle_members` table for recipient picker
  - [x] Insert both parties as members on handshake confirm
  - [x] TimelineEntry model: senderID, senderCallsign, targetRecipients, canReveal
  
- [ ] **Ephemeral per-post keys** (deferred to follow-up PR)
  - [ ] `Scramble.generateEphemeralKey()`, `wrapKey()`, `unwrapKey()`
  - [ ] Compose with ephemeral key wrapping per recipient
  - [ ] Reveal with ephemeral key unwrap
  - [ ] Crypto tests for ephemeral keys

## 🎯 POC Demo Script

1. Alice opens Veu → generates Ghost identity from seed
2. Alice generates a Dead Link → Bob scans QR
3. Both see matching 8-digit code → tap "Seal" → Emerald bloom fires ✅
4. Alice captures a photo → app encrypts it → Aura shader renders the Glaze
5. Bob's phone receives the artifact over local Wi-Fi
6. Bob long-presses → FaceID → shader lifts → photo revealed