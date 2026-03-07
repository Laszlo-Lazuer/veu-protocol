/// Errors thrown by the VeuCrypto library.
public enum VeuCryptoError: Error {
    /// AES-256-GCM encryption failed.
    case encryptionFailed
    /// AES-256-GCM decryption failed — authentication tag mismatch or corrupt ciphertext.
    case decryptionFailed
    /// The raw bytes do not conform to the .veu artifact format.
    case invalidArtifactFormat
    /// The requested key has already been burned and is no longer available.
    case keyBurned
    /// HKDF or another key-derivation step failed.
    case keyDerivationFailed
}
