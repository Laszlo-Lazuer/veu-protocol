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
- `/apps/veu-mobile`: The primary mobile interface (Physical-first).

---
*Veu is currently in the "Riff" phase. Built for the Dark Forest.*