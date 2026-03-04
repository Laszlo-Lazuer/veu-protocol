# veu-crypto: The Scramble Specification

This package defines the core cryptographic operations for the Veu protocol. It handles the transformation of raw content (Photos/Videos) into "Glazed" artifacts.

## 1. The Scramble Process (Encryption)

Veu uses **AES-256-GCM** (Galois/Counter Mode) for authenticated encryption. This ensures both privacy and integrity—if a scrambled blob is tampered with, it will fail to unscramble.

### Workflow:
1.  **Key Generation:** A unique 256-bit `SymmetricKey` is generated for the artifact (or derived from the Circle Key).
2.  **Nonce:** A random 96-bit Initialization Vector (IV) is generated.
3.  **Encryption:** The raw content is encrypted using AES-256-GCM.
4.  **Tag:** The 128-bit Authentication Tag is appended to the ciphertext.

## 2. The Glaze Derivation (Deterministic Art Seed)

To create the "Double Mirror" effect, we need a way for the public art to be consistent for a specific file without revealing the file's contents.

### The Seed Algorithm:
1.  Take the **Ciphertext** (the encrypted bytes).
2.  Apply **HMAC-SHA-256** using a "Glaze Salt" (shared within the Circle) as the key.
3.  The resulting 256-bit hash is the **Glaze Seed**.
4.  This seed is passed to the GLSL shader in `veu-glaze` to generate the abstract art.

**Why this works:**
- **Deterministic:** The same encrypted file always produces the same art.
- **One-Way:** You cannot reverse the Glaze Seed to find the original photo pixels.
- **Privacy-Preserving:** Even if two people post the exact same photo, if they use different Circle Keys, the "Glaze" art will look completely different.

## 3. The Artifact Structure

A `.veu` artifact is a binary blob structured as follows:

| Offset | Length | Description |
| :--- | :--- | :--- |
| 0 | 12 bytes | Initialization Vector (Nonce) |
| 12 | 16 bytes | Authentication Tag |
| 28 | Variable | AES-256-GCM Encrypted Content |

## 4. Hardware-Bound Security

All encryption/decryption keys must be stored in the device's **Secure Enclave** or **Trusted Execution Environment (TEE)**. Keys should never be exported in plaintext.