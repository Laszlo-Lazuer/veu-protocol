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
public struct CircleKey: Codable {
    // TODO: In production, replace raw keyData storage with Secure Enclave key references
    //       (SecKey / CryptoKit's SecureEnclave.P256) so the key material never leaves
    //       the hardware security boundary.

    /// The underlying AES-256 symmetric key (stored as Data for Codable).
    private let keyDataStorage: Data
    
    /// 128-bit (16-byte) random salt used for Glaze Seed derivation.
    public let glazeSalt: Data
    
    /// The underlying AES-256 symmetric key.
    public var symmetricKey: SymmetricKey {
        SymmetricKey(data: keyDataStorage)
    }

    /// Raw key bytes — provided for serialisation / testing.
    /// - Warning: Never store this value in plaintext outside the POC.
    public var keyData: Data {
        keyDataStorage
    }

    // MARK: - Initialisation

    /// Generate a fresh random Circle Key with a matching Glaze salt.
    public static func generate() -> CircleKey {
        let key  = SymmetricKey(size: .bits256)
        let salt = SymmetricKey(size: .bits128)
        let keyData = key.withUnsafeBytes { Data($0) }
        let saltData = salt.withUnsafeBytes { Data($0) }
        return CircleKey(keyData: keyData, glazeSalt: saltData)
    }

    /// Reconstruct a `CircleKey` from previously serialised raw bytes.
    /// - Parameters:
    ///   - keyData:   32 bytes of AES-256 key material.
    ///   - glazeSalt: 16 bytes of Glaze salt.
    public init(keyData: Data, glazeSalt: Data) {
        self.keyDataStorage = keyData
        self.glazeSalt = glazeSalt
    }
}
