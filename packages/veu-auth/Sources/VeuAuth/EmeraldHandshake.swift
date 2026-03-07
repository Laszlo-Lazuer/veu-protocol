// EmeraldHandshake.swift — Veu Protocol: X25519 Key Exchange & State Machine
//
// Implements the cryptographic core of the Emerald Handshake ceremony:
// - Ephemeral X25519 keypair generation
// - ECDH shared secret computation
// - HKDF-SHA-256 Circle key derivation
// - 7-phase handshake state machine (matching EMERALD_HANDSHAKE.md)

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import VeuCrypto

// MARK: - Handshake Phase

/// The seven visual/cryptographic phases of the Emerald Handshake ceremony.
///
/// Phases 0–4 are the success path; phases 5–6 are failure states.
/// These map directly to the `u_phase` uniform in `EMERALD.glsl`.
public enum HandshakePhase: Int, Equatable, CaseIterable, Sendable {
    /// No handshake in progress.
    case idle = 0
    /// Initiating peer has generated ephemeral keypair and Dead Link.
    case initiating = 1
    /// Responding peer has sent their public key; both sides computing shared secret.
    case awaiting = 2
    /// Both peers independently derived the short code; awaiting user verification.
    case verifying = 3
    /// Both peers confirmed the short code; Circle key stored.
    case confirmed = 4
    /// Dead Link expired or was revoked.
    case deadLink = 5
    /// Handshake timed out or was rejected.
    case ghost = 6
}

// MARK: - Ephemeral Keypair

/// An ephemeral X25519 keypair generated for a single handshake session.
///
/// The private key is held only in memory and must be zeroed after the
/// handshake completes or fails.
public struct EphemeralKeypair {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKey: Curve25519.KeyAgreement.PublicKey

    /// Generate a fresh random ephemeral keypair.
    public static func generate() -> EphemeralKeypair {
        let sk = Curve25519.KeyAgreement.PrivateKey()
        return EphemeralKeypair(privateKey: sk, publicKey: sk.publicKey)
    }
}

// MARK: - Emerald Handshake

/// Core cryptographic operations for the Emerald Handshake ceremony.
///
/// This enum serves as a namespace for pure functions that implement the
/// key exchange and derivation steps specified in `EMERALD_HANDSHAKE.md`.
public enum EmeraldHandshake {

    /// The HKDF salt used when deriving the Circle key from the shared secret.
    /// Matches the spec in EMERALD_HANDSHAKE.md §Phase 3.
    public static let circleKeySalt = "veu-circle-v1"

    // MARK: - Key Agreement

    /// Perform X25519 ECDH to derive a raw shared secret.
    ///
    /// - Parameters:
    ///   - localPrivateKey: The local peer's ephemeral X25519 private key.
    ///   - remotePublicKey: The remote peer's ephemeral X25519 public key.
    /// - Throws: `VeuAuthError.keyAgreementFailed` if ECDH fails.
    /// - Returns: The raw 32-byte shared secret.
    public static func sharedSecret(
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> SharedSecret {
        do {
            return try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        } catch {
            throw VeuAuthError.keyAgreementFailed
        }
    }

    /// Derive a Circle key from the ECDH shared secret using HKDF-SHA-256.
    ///
    /// ```
    /// circle_key = HKDF-SHA-256(
    ///     ikm  = shared_secret,
    ///     salt = "veu-circle-v1",
    ///     info = circle_id,
    ///     len  = 32
    /// )
    /// ```
    ///
    /// The resulting `CircleKey` includes a deterministic Glaze salt derived
    /// from the same shared secret (using a separate info parameter).
    ///
    /// - Parameters:
    ///   - sharedSecret: The raw X25519 shared secret.
    ///   - circleID: The identifier for the new Circle (used as HKDF info).
    /// - Throws: `VeuAuthError.keyDerivationFailed` if derivation fails.
    /// - Returns: A `CircleKey` (from `VeuCrypto`) with key + Glaze salt.
    public static func deriveCircleKey(
        from sharedSecret: SharedSecret,
        circleID: String
    ) throws -> CircleKey {
        guard let infoData = circleID.data(using: .utf8) else {
            throw VeuAuthError.keyDerivationFailed
        }
        guard let saltData = EmeraldHandshake.circleKeySalt.data(using: .utf8) else {
            throw VeuAuthError.keyDerivationFailed
        }

        // Derive the 256-bit Circle symmetric key
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: infoData,
            outputByteCount: 32
        )

        // Derive a 128-bit Glaze salt using a separate info parameter
        guard let glazeInfo = "veu-glaze-salt-v1".data(using: .utf8) else {
            throw VeuAuthError.keyDerivationFailed
        }
        let glazeSymKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: glazeInfo,
            outputByteCount: 16
        )
        let glazeSalt = glazeSymKey.withUnsafeBytes { Data($0) }

        let keyData = symmetricKey.withUnsafeBytes { Data($0) }
        return CircleKey(keyData: keyData, glazeSalt: glazeSalt)
    }

    /// Perform the full key exchange and derivation in one call.
    ///
    /// - Parameters:
    ///   - localPrivateKey: The local peer's ephemeral X25519 private key.
    ///   - remotePublicKey: The remote peer's ephemeral X25519 public key.
    ///   - circleID: The identifier for the new Circle.
    /// - Throws: `VeuAuthError.keyAgreementFailed` or `.keyDerivationFailed`.
    /// - Returns: A `CircleKey` derived from the ECDH shared secret.
    public static func performKeyExchange(
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Curve25519.KeyAgreement.PublicKey,
        circleID: String
    ) throws -> CircleKey {
        let ss = try sharedSecret(localPrivateKey: localPrivateKey, remotePublicKey: remotePublicKey)
        return try deriveCircleKey(from: ss, circleID: circleID)
    }
}
