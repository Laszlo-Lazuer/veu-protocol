# veu-auth: The Unified Handshake

The Handshake is the only way to bridge two "Islands" (Devices) in the Veu protocol. It combines a one-time cryptographic exchange with a human-verified ritual.

## 🤝 The "Emerald" Protocol
The Handshake uses a **Short Authentication String (SAS)** to prevent Man-in-the-Middle (MITM) attacks.

### 1. The Initiation
- Alice generates a `HandshakeSecret` and encodes it into a one-time QR or Link.
- The link contains Alice's **Hardware Public Key**.

### 2. The Exchange
- Bob scans/clicks. His phone generates its own keypair and sends its **Public Key** back to Alice.
- Both phones now compute a **Shared Secret** using ECDH (Elliptic Curve Diffie-Hellman).

### 3. The Ritual (The Verification)
From the Shared Secret, both phones derive:
- **The Aura Color:** A specific hex code for the background (visual verification).
- **The 8-Digit Code:** A string of 8 numbers (verbal verification).

### 4. The Seal
- Once both users tap "Verify," the **Circle Ledger** is updated on both devices.
- The link is marked as **BURNED** and the `HandshakeSecret` is deleted from memory.

## 🛡️ Security Guarantees
- **No Third Party:** No server ever sees the Shared Secret or the 8-Digit Code.
- **One-Way:** Knowing the color/code does not reveal the underlying keys.
- **Ephemeral:** If the ritual is not completed within a 5-minute window, the handshake expires and the secret is purged from the Secure Enclave.