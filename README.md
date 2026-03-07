# Veu (Voo)

> **Veu the truth. Glaze the rest.**

Veu is a sovereign, intimate social protocol built on the metaphor of the **Double Mirror**. It is designed for those who want to maintain deep connections without the noise, surveillance, or context-collapse of the modern web.

## 🪞 The Double Mirror Philosophy
In a two-way mirror, one side sees a reflection, while the other sees through to the truth. Veu applies this to digital identity:
*   **The Glaze (Public):** To the outside world, your profile and posts are "Glazed"—scrambled into generative, abstract digital art. It is a beautiful mask that reveals nothing of the underlying data.
*   **The Vue (Private):** To your verified "Circles," the Glaze is lifted. Your friends see the real photo, the real text, and the real you.

## 🛡️ Core Pillars
*   **Zero Overlap:** No global discovery, no "People You May Know," and no interconnected social graphs. Each Circle is a cryptographic island.
*   **Hardware-Bound Identity:** We use **WebAuthn (Passkeys)** and Hardware Attestation to prove you are a unique human without requiring biometrics or real-world IDs.
*   **Total Sovereignty:** Your identity is derived from a **24-word seed phrase (BIP-39)**. There are no "accounts" on a central server—only keys you own.
*   **One-Time Handshakes:** Connections are made via one-time-use "Dead Links" and a physical verification ritual (8-digit short codes).

## 🛠️ Technical Stack
- **Encryption:** AES-256-GCM for content "Glazing"; Curve25519 for Circle handshakes.
- **Storage:** IPFS (Content-addressed, encrypted blobs).
- **Auth:** Passkeys / Secure Enclave integration.
- **Art:** Generative GLSL shaders seeded by file hashes to create the "Glaze."

## 🏗️ Repository Structure
- `/packages/veu-crypto`: The encryption and "Glaze" logic.
- `/packages/veu-auth`: Hardware attestation and seed phrase derivation.
- `/packages/veu-glaze`: Generative art engine for the public mask.
- `/packages/veu-protocol`: Ghost Network sync layer and Zero-Aware delta-sync.
- `/packages/veu-app`: Double Mirror UX and Zero-Aware EULA.

## 🧪 Testing — Phase 1: Crypto Core (`veu-crypto`)

The `veu-crypto` Swift Package is the cryptographic foundation of Veu. It implements AES-256-GCM encryption, HMAC-SHA-256 Glaze Seed derivation, and the Burn Engine. No device or simulator required — it runs entirely via the Swift Package Manager.

### Prerequisites
- **Swift 5.9+** — check with `swift --version`
- **macOS 13+** (Ventura or later)

### Run the tests

```bash
# Clone the repo
git clone https://github.com/Laszlo-Lazuer/veu-protocol.git
cd veu-protocol/packages/veu-crypto

# Run all tests
swift test
```

### What the tests cover

| Test Suite | What it verifies |
| :--- | :--- |
| `ScrambleTests` | ✅ Round-trip encrypt → decrypt returns original data |
| | ✅ Tamper detection — mutating 1 ciphertext byte throws `decryptionFailed` |
| | ✅ Different keys produce different ciphertexts |
| `GlazeSeedTests` | ✅ Determinism — same ciphertext + salt → same 32-byte seed |
| | ✅ Salt sensitivity — different salts → different seeds |
| | ✅ Seed is always exactly 32 bytes |
| `BurnTests` | ✅ After `burn()`, `isBurned()` returns `true` |
| | ✅ After `burnAll()`, all tracked artifact IDs are burned |

### Run in Xcode (optional)

```bash
# Open the package directly in Xcode
open packages/veu-crypto/Package.swift
```

Then press `⌘U` to run all tests.

---
*Veu is currently in active POC development. See [ROADMAP.md](./ROADMAP.md) for the full implementation queue.*