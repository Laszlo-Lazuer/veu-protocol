# POST_QUANTUM.md — Veu Protocol: Post-Quantum Hardening

> **Status:** Design — not yet implemented.  This document is the authoritative
> specification for migrating the Veu cryptographic stack from classical
> primitives to NIST-standardised post-quantum algorithms.

---

## 1. Current Cryptographic Primitives and Quantum Vulnerability

| Primitive | Algorithm | Purpose in Veu | Quantum attack | Cost to break (Grover / Shor) |
|-----------|-----------|----------------|----------------|-------------------------------|
| Key Agreement | X25519 (Curve25519 ECDH) | Emerald Handshake, Circle key establishment | Shor's algorithm | O(1) on a CRQC — **broken** |
| Symmetric Encryption | AES-256-GCM | Artifact scramble, `encrypted_meta` in Ledger | Grover's algorithm | Effective key length halved to 128 bits — **acceptable** |
| MAC / Glaze Seed | HMAC-SHA-256 | Glaze Seed derivation, short-code verification | Grover's algorithm | Effective security 128 bits — **acceptable** |
| Key Derivation | HKDF-SHA-256 | Circle key derivation from shared secret | Grover's algorithm | Effective security 128 bits — **acceptable** |
| Attestation Signatures | P-256 (WebAuthn / App Attest) | Hardware-bound identity, Dead Link signing | Shor's algorithm | O(1) on a CRQC — **broken** |

**Summary:** the symmetric layer (AES-256-GCM, HMAC-SHA-256) is quantum-safe
at the 128-bit level under Grover's algorithm, which is broadly considered
acceptable.  The asymmetric layer (X25519, P-256) is completely broken by
Shor's algorithm running on a Cryptographically Relevant Quantum Computer
(CRQC).  The Veu protocol must replace or augment all asymmetric operations.

> **"Harvest now, decrypt later"** threat model: adversaries are already
> recording Veu Ghost Network traffic today.  Once a CRQC exists, they can
> retroactively decrypt all historically recorded handshakes.  This makes
> migration **urgent**, not merely forward-looking.

---

## 2. Selected Post-Quantum Algorithms

All selected algorithms are finalised NIST post-quantum standards (FIPS 203,
FIPS 204, FIPS 205) or the NIST SP 800-208 recommendation.

### 2.1 Key Encapsulation: ML-KEM (Kyber-1024) — FIPS 203

| Property | Value |
|----------|-------|
| Standard | FIPS 203 (ML-KEM) |
| Parameter set | Kyber-1024 |
| NIST security level | Level 5 (≥256-bit classical, ≥128-bit quantum) |
| Public key size | 1 568 bytes |
| Ciphertext size | 1 568 bytes |
| Shared secret size | 32 bytes |
| Replaces | X25519 key agreement in the Emerald Handshake |

Kyber-1024 is a lattice-based (Module-LWE) key encapsulation mechanism.  It
is chosen over Kyber-512 / Kyber-768 to achieve NIST Level 5 security,
consistent with the Veu threat model of long-lived Circle keys.

### 2.2 Signatures: ML-DSA (Dilithium-5) — FIPS 204

| Property | Value |
|----------|-------|
| Standard | FIPS 204 (ML-DSA) |
| Parameter set | Dilithium-5 |
| NIST security level | Level 5 |
| Public key size | 2 592 bytes |
| Signature size | 4 595 bytes |
| Replaces | P-256 in Dead Link signing, WebAuthn attestation binding |

ML-DSA is a lattice-based (Module-LWE / Module-SIS) digital signature scheme.
Dilithium-5 is selected for its conservative security margin.  Its larger
signature size has an acceptable impact on Dead Link URL/QR code encoding (see
§5).

### 2.3 Stateless Hash-Based Signatures: SPHINCS+ — FIPS 205

| Property | Value |
|----------|-------|
| Standard | FIPS 205 (SLH-DSA) |
| Parameter set | SPHINCS+-SHA-256-256f (fast variant) |
| NIST security level | Level 5 |
| Public key size | 64 bytes |
| Signature size | 49 856 bytes |
| Role | Fallback / long-term identity anchor |

SPHINCS+ is included as a **stateless hash-based** fallback because its
security rests entirely on the security of SHA-256, with no algebraic
structure that could be targeted by novel attacks.  It is not used for
high-frequency operations (signature size is too large for real-time use) but
is used to sign the device's long-term identity certificate at enrollment,
providing a "last resort" anchor.

---

## 3. Hybrid Transition Strategy

The migration from classical to post-quantum algorithms must not break
compatibility with devices running earlier Veu versions during the transition
window.  A **hybrid construction** is used during this period: both a
classical and a post-quantum algorithm are run in parallel, and the outputs
are combined.  Only when all parties in a Circle have upgraded to PQ-capable
Veu clients will the classical path be retired.

### 3.1 Hybrid Key Encapsulation (X25519 + ML-KEM-1024)

During Phase 1 (see §7), the Emerald Handshake produces two shared secrets:

```
ss_classical = X25519(esk_A, epk_B)      // Curve25519 ECDH
ss_pq        = ML-KEM-1024.Dec(ct, esk_B_pq)  // Kyber shared secret

combined_secret = HKDF-SHA-256(
    ikm    = ss_classical || ss_pq,       // concatenate both secrets
    salt   = "veu-hybrid-v1",
    info   = circle_id || protocol_version,
    length = 32
)
```

The combined secret feeds the existing Circle key derivation.  An adversary
must break **both** X25519 **and** ML-KEM-1024 to recover `combined_secret`.

### 3.2 Hybrid Signatures (P-256 + ML-DSA-Dilithium-5)

Dead Link URLs and attestation certificates carry two signatures during the
transition:

```
sig_classical = ECDSA-P256.Sign(sk_p256, message)
sig_pq        = ML-DSA-5.Sign(sk_dilithium, message)
```

A verifier on an older client accepts if `sig_classical` is valid.  A
verifier on a PQ-capable client requires **both** signatures to be valid.

### 3.3 Protocol Negotiation

Clients advertise their PQ capability in the handshake `ClientHello`
extension:

```
capability_flags:
  bit 0 = supports ML-KEM-1024
  bit 1 = supports ML-DSA-Dilithium-5
  bit 2 = supports SPHINCS+
```

Both peers intersect their flags.  If both support ML-KEM, the hybrid
construction upgrades automatically; if only one does, the classical path is
used (with a UI warning on the PQ-capable client).

---

## 4. Impact on the Emerald Handshake

### 4.1 Message Size Changes

| Field | Classical | Hybrid (Phase 1) | PQ-only (Phase 3) |
|-------|-----------|------------------|-------------------|
| epk_A (initiating peer public key) | 32 bytes (X25519) | 32 + 1 568 = 1 600 bytes | 1 568 bytes (ML-KEM) |
| epk_B (response public key) | 32 bytes | 32 + 1 568 = 1 600 bytes | 1 568 bytes |
| KEM ciphertext | 0 bytes | 1 568 bytes | 1 568 bytes |
| Attestation signature | 64 bytes (P-256) | 64 + 4 595 = 4 659 bytes | 4 595 bytes (ML-DSA) |

**Dead Link URL / QR code:** the ML-KEM public key (1 568 bytes) cannot fit
in a standard QR code URL parameter.  Mitigation options (to be decided in
§8):
  - Store epk_A on the Ghost Network relay node (keyed by a short random
    token in the URL) — the relay sees only ciphertext, consistent with
    Zero-Aware design.
  - Use a QR code with high-density mode (QR Level H, ~3 000 bytes capacity).
  - Split across two QR codes with a "scan both" UX.

### 4.2 Handshake Latency

ML-KEM-1024 key generation, encapsulation, and decapsulation are all
sub-millisecond on modern hardware.  ML-DSA-5 signing is ~0.5 ms and
verification is ~0.1 ms.  No perceptible impact on ceremony visual smoothness.

### 4.3 Short-Code Derivation

The short-code derivation is unchanged:

```
short_code = first 4 bytes of HMAC-SHA-256(circle_key, "short-code") → 8 hex digits
```

`circle_key` is now derived from `combined_secret` (hybrid) or from the ML-KEM
shared secret alone (PQ-only phase), but the derivation function and short-code
format are identical, so the `VERIFYING` phase of the visual ceremony requires
no changes.

---

## 5. Impact on the Local Artifact Ledger

### 5.1 Re-encryption Migration Path

All `encrypted_meta` blobs in `LEDGER.sql` are encrypted with the Circle key
derived from a classical (X25519) handshake.  When a Circle upgrades to hybrid
or PQ-only key establishment:

1. The new Circle key is established via the PQ handshake.
2. **Re-wrapping** (not re-encryption of the artifact ciphertext itself):
   - Decrypt `encrypted_meta` with the old Circle key.
   - Re-encrypt `encrypted_meta` with the new Circle key.
   - Update the `artifacts` row in-place (no new CID required — the artifact
     ciphertext blob on IPFS is unchanged).
3. Re-wrapping is performed lazily on next app open, per-Circle.
4. A `ledger_meta.schema_version` bump (v1 → v2) signals that re-wrapping has
   been completed on this device.

### 5.2 No Impact on Artifact CIDs

Artifact CIDs are derived from the AES-256-GCM ciphertext of the content, not
from any asymmetric key material.  CIDs remain stable across the PQ migration.

### 5.3 Key Storage

Post-quantum private keys (esk_pq for ML-KEM, sk_dilithium for ML-DSA) must
be stored in the Secure Enclave / TEE.  Current Secure Enclave implementations
support opaque key storage for arbitrary key types, so this is compatible with
the existing hardware-bound key architecture.

---

## 6. Security Level Targets

| Operation | Target NIST Level | Algorithm | Achieved? |
|-----------|------------------|-----------|-----------|
| Circle key establishment | Level 5 | ML-KEM-1024 (hybrid with X25519) | Phase 1 |
| Artifact attestation / Dead Link signing | Level 5 | ML-DSA-Dilithium-5 | Phase 2 |
| Long-term identity anchor | Level 5 | SPHINCS+-SHA-256-256f | Phase 2 |
| Symmetric artifact encryption | Level 5 (128-bit quantum) | AES-256-GCM | Already met |
| Key derivation | Level 5 | HKDF-SHA-256 | Already met |

---

## 7. Implementation Phasing

### Phase 1 — Key Encapsulation (Priority: High)

- Integrate `libpqcrystals/kyber` (reference implementation) or a
  platform-native ML-KEM implementation.
- Update the Emerald Handshake to generate hybrid ephemeral keypairs.
- Update `HKDF` input to include both `ss_classical` and `ss_pq`.
- Add `capability_flags` to handshake `ClientHello`.
- Dead Link URL: implement relay-stored epk_A as described in §4.1.
- Update `EMERALD_HANDSHAKE.md` to document hybrid key sizes.
- **Does not break** existing classical-only clients during transition window.

### Phase 2 — Signatures (Priority: Medium)

- Integrate ML-DSA (Dilithium-5) for Dead Link signing and attestation
  certificate binding.
- Add SPHINCS+ for long-term identity certificate signing at enrollment.
- Deploy hybrid signature verification (`sig_classical` OR `sig_pq`
  depending on client capability).
- Update `veu-auth` hardware attestation to bind ML-DSA public keys to the
  Secure Enclave attestation object.

### Phase 3 — Full Classical Deprecation (Priority: Low / Future)

- After a defined sunset date (minimum 24 months from Phase 1 deployment),
  deprecate X25519-only handshake paths.
- Remove `sig_classical` from Dead Link payloads.
- Update minimum Veu version requirement.
- Perform final `LEDGER.sql` schema migration (v2 → v3) to record full PQ
  status per-Circle.

---

## 8. Open Questions and Deferred Decisions

1. **Dead Link URL encoding for ML-KEM public keys** — Three options in §4.1;
   final choice deferred pending UX research on QR code scanning latency.

2. **Platform ML-KEM availability** — Apple CryptoKit and BoringSSL (Android)
   are expected to ship ML-KEM support in 2025/2026.  If platform APIs are
   available before Phase 1 implementation begins, prefer them over bundled
   `libpqcrystals` to avoid supply-chain risk and ensure FIPS validation.

3. **Secure Enclave key size limits** — Some SEP implementations restrict
   the maximum storable key blob size.  ML-DSA-5 secret keys are 4 864 bytes;
   this must be validated against the target device's SEP constraints before
   committing to Dilithium-5 over Dilithium-3 (NIST Level 3, smaller keys).

4. **Re-wrapping UX** — Re-wrapping `encrypted_meta` for large Circles with
   many artifacts may take several seconds.  A progress indicator in the app
   is required; the blocking UX for this is not yet designed.

5. **SPHINCS+ key rotation** — SPHINCS+ is stateless, so key rotation is
   straightforward; however, rotating the long-term identity key requires
   re-signing all stored attestation certificates.  A ceremony UX for this
   is deferred to Phase 2 design.

6. **Quantum random number generation** — Current ephemeral key generation
   relies on OS-provided CSPRNG.  Whether to mandate a hardware quantum RNG
   (available on some devices) or treat OS CSPRNG as sufficient is deferred.
