#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Namespace for AES-256-GCM encrypt / decrypt operations.
public enum Scramble {
    /// Encrypt `data` with AES-256-GCM using `key`.
    ///
    /// A fresh random 96-bit nonce is generated for every call.
    /// - Parameters:
    ///   - data: Plaintext bytes to encrypt.
    ///   - key:  256-bit symmetric key.
    /// - Returns: A `VeuArtifact` containing the IV, authentication tag, and ciphertext.
    /// - Throws: `VeuCryptoError.encryptionFailed`
    public static func scramble(data: Data, using key: SymmetricKey) throws -> VeuArtifact {
        do {
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

            let iv  = Data(sealedBox.nonce)
            let tag = sealedBox.tag
            let ciphertext = sealedBox.ciphertext

            return VeuArtifact(iv: iv, tag: tag, ciphertext: ciphertext)
        } catch {
            throw VeuCryptoError.encryptionFailed
        }
    }

    /// Decrypt a `VeuArtifact` with AES-256-GCM using `key`.
    ///
    /// The authentication tag is verified automatically; any tampering causes a throw.
    /// - Parameters:
    ///   - artifact: The `.veu` artifact to decrypt.
    ///   - key:      256-bit symmetric key that was used to encrypt.
    /// - Returns: The original plaintext bytes.
    /// - Throws: `VeuCryptoError.decryptionFailed` on tag mismatch or corrupt data.
    public static func unscramble(artifact: VeuArtifact, using key: SymmetricKey) throws -> Data {
        do {
            let nonce     = try AES.GCM.Nonce(data: artifact.iv)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce,
                                                   ciphertext: artifact.ciphertext,
                                                   tag: artifact.tag)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw VeuCryptoError.decryptionFailed
        }
    }
}
