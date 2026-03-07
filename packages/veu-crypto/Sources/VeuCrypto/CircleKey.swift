#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A Circle-level 256-bit symmetric key together with its associated Glaze salt.
///
/// In a production build, `keyData` would be managed by the Secure Enclave and never
/// exported in plaintext. In this POC it is exposed as raw `Data` for testability.
public struct CircleKey {
    // TODO: In production, replace raw keyData storage with Secure Enclave key references
    //       (SecKey / CryptoKit's SecureEnclave.P256) so the key material never leaves
    //       the hardware security boundary.

    /// The underlying AES-256 symmetric key.
    public let symmetricKey: SymmetricKey

    /// 128-bit (16-byte) random salt used for Glaze Seed derivation.
    public let glazeSalt: Data

    /// Raw key bytes — provided for serialisation / testing.
    /// - Warning: Never store this value in plaintext outside the POC.
    public var keyData: Data {
        symmetricKey.withUnsafeBytes { Data($0) }
    }

    // MARK: - Initialisation

    private init(symmetricKey: SymmetricKey, glazeSalt: Data) {
        self.symmetricKey = symmetricKey
        self.glazeSalt    = glazeSalt
    }

    /// Generate a fresh random Circle Key with a matching Glaze salt.
    public static func generate() -> CircleKey {
        let key  = SymmetricKey(size: .bits256)
        let salt = SymmetricKey(size: .bits128)
        let saltData = salt.withUnsafeBytes { Data($0) }
        return CircleKey(symmetricKey: key, glazeSalt: saltData)
    }

    /// Reconstruct a `CircleKey` from previously serialised raw bytes.
    /// - Parameters:
    ///   - keyData:   32 bytes of AES-256 key material.
    ///   - glazeSalt: 16 bytes of Glaze salt.
    public init(keyData: Data, glazeSalt: Data) {
        self.symmetricKey = SymmetricKey(data: keyData)
        self.glazeSalt    = glazeSalt
    }
}
