# veu-crypto: Artifact Burn & Ephemeral Storage

In the Veu protocol, "Deletion" is not a request sent to a server; it is a cryptographic event. When an artifact is burned, it must become mathematically impossible to recover, even if the encrypted bytes remain on the network.

## 🧨 The "Double-Key" Burn Mechanism

Veu uses a dual-layer approach to ensure that a burned post stays dead.

### 1. The Local Key Purge (Instant Deletion)
Each artifact is encrypted with a unique **Artifact Key**, which is itself encrypted by the **Circle Key** and stored in the owner's **Circle Ledger**.
- **Action:** When a user taps "Burn," the device securely wipes the Artifact Key from the local Ledger and the Secure Enclave.
- **Result:** Even if the owner has a backup of the encrypted file, they can no longer decrypt it.

### 2. The Network "Tombstone" (Propagation)
Veu utilizes a decentralized storage layer (IPFS/Filecoin). To delete a file from a network you don't control, we use **Cryptographic Revocation**.
- **The Tombstone:** The device publishes a signed "Revocation Packet" to the Circle's synchronization channel.
- **Peer Action:** When other devices in the Circle receive this packet, they automatically delete the corresponding Artifact Key from their local ledgers and purge the cached file from their device storage.

## ⏱️ Ephemeral Defaults (Auto-Burn)

Veu is designed for "Digital Presence," not "Digital Archiving." 

### 1. The Pulse Timer
Users can set a "Lifespan" for any artifact:
- **Momentary:** 1 hour (The "Smoke" effect).
- **Daily:** 24 hours.
- **Permanent:** Until manually burned (default for "Circle Memories").

### 2. Hardware Enforcement
The **A14+ Secure Enclave** manages these timers. If a "Momentary" post's time expires, the Secure Enclave will refuse to provide the decryption key, effectively burning the content even if the app is offline.

## 🛡️ Anti-Forensic Measures
- **Zero-Overwrite:** When a key is deleted, the app performs a multi-pass overwrite of that memory sector to prevent recovery via physical forensic tools.
- **Cache Scrubbing:** Every time an artifact is viewed, it is decrypted into volatile memory (RAM) only. It is never written to the disk in plaintext.

## 🚫 The "Ghost" Problem
If a member of the Circle takes a physical photo of the screen (an "Analog Hole"), the digital burn cannot stop that. Veu is a protocol for **Consent**, not a solution for **Malice**.