#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A per-artifact 256-bit symmetric key used with AES-256-GCM.
///
/// Artifact keys can be generated randomly (`generate()`) or derived
/// deterministically from a Circle Key via HKDF-SHA256 (`derived(from:artifactID:)`).
public struct ArtifactKey {
    // TODO: In production, key material should be sealed inside the Secure Enclave.
    //       Use SecureEnclave.P256 or CryptoKit's sealed key APIs instead of raw
    //       SymmetricKey so that keys are hardware-bound and non-exportable.

    /// The underlying AES-256 symmetric key.
    public let symmetricKey: SymmetricKey

    private init(_ symmetricKey: SymmetricKey) {
        self.symmetricKey = symmetricKey
    }

    /// Generate a fresh random per-artifact key.
    public static func generate() -> ArtifactKey {
        ArtifactKey(SymmetricKey(size: .bits256))
    }

    /// Deterministically derive an artifact key from a Circle Key and a unique artifact ID.
    ///
    /// Uses HKDF-SHA256 with:
    /// - Input key material: the Circle Key
    /// - Info: UTF-8 encoding of the artifact UUID string
    /// - Output: 256 bits
    ///
    /// - Parameters:
    ///   - circleKey:  The Circle's master symmetric key.
    ///   - artifactID: The UUID that uniquely identifies the artifact.
    /// - Returns: A deterministic `ArtifactKey` for the given `(circleKey, artifactID)` pair.
    /// - Throws: `VeuCryptoError.keyDerivationFailed`
    public static func derived(from circleKey: CircleKey, artifactID: UUID) throws -> ArtifactKey {
        guard let info = artifactID.uuidString.data(using: .utf8) else {
            throw VeuCryptoError.keyDerivationFailed
        }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: circleKey.symmetricKey,
            info: info,
            outputByteCount: 32
        )
        return ArtifactKey(derived)
    }
}
