# Veu Protocol: Development Roadmap & "What's Next"

This document serves as the persistent context for the Veu protocol's development. As of **2026-03-07**, we are in active POC implementation.

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
- **Phase 3 — The Glaze Engine** (`packages/veu-glaze/`): Swift Package implementing GLSL→Metal shader translation (AURA + EMERALD), MetalRenderer base pipeline with runtime MSL compilation, AuraView + EmeraldView SwiftUI wrappers, Vue Toggle (long-press → biometric → reveal), and HapticEngine (heartbeat/burn/hum). 34 tests passing (`swift test`).

## 🏗️ POC Implementation Queue

### Phase 2 — The Handshake (`veu-auth`) 🤝
> _Two devices perform a live Emerald Handshake — the core trust primitive._

- [x] Dead Link URI generation (`veu://handshake?pk=…&exp=…&sig=…`)
- [x] Curve25519 ECDH key exchange → Shared Secret derivation
- [x] SAS derivation: Shared Secret → 8-digit code + Aura color hex
- [x] Bootstrap `LEDGER.sql` SQLite schema into a Swift Package (`veu-auth`)
- [ ] Minimal handshake UI: QR code display + 8-digit confirmation screen

### Phase 3 — The Glaze Engine (`veu-glaze` + `veu-app`) 🎨
> _Wire the GLSL shaders to real cryptographic data._

- [x] `AuraView` (SwiftUI + Metal): load `AURA.glsl`, feed `u_seed_color` from Glaze Seed
- [x] `EmeraldView`: load `EMERALD.glsl`, drive `u_phase` from handshake state machine
- [x] Vue Toggle: long-press → FaceID → shader opacity 0 → reveal artifact
- [x] `HapticEngine`: handshake heartbeat, burn click, vue hum

### Phase 4 — Ghost Network (minimal) 📡
> _Artifact sync between two devices with no central server._

- [ ] Local Pulse: mDNS/Bonjour peer discovery on same Wi-Fi
- [ ] Artifact publish: encrypt artifact → push to peer over local connection
- [ ] Artifact Ledger sync: update `LEDGER.sql` on receive, drive UI
- [ ] _Post-POC: IPFS + Tor integration_

## 🎯 POC Demo Script

1. Alice opens Veu → generates Ghost identity from seed
2. Alice generates a Dead Link → Bob scans QR
3. Both see matching 8-digit code → tap "Seal" → Emerald bloom fires ✅
4. Alice captures a photo → app encrypts it → Aura shader renders the Glaze
5. Bob's phone receives the artifact over local Wi-Fi
6. Bob long-presses → FaceID → shader lifts → photo revealed