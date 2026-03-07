import Foundation

/// The binary layout of a `.veu` artifact as defined in the Veu protocol spec.
///
/// Memory layout:
/// - Bytes  0 –  11 : 96-bit Initialization Vector (Nonce)
/// - Bytes 12 –  27 : 128-bit AES-GCM Authentication Tag
/// - Bytes 28+      : AES-256-GCM Encrypted Content
public struct VeuArtifact {
    /// Minimum byte count for a valid artifact (IV + Tag, no ciphertext).
    private static let headerSize = 28

    /// 96-bit (12-byte) nonce used during encryption.
    public let iv: Data

    /// 128-bit (16-byte) AES-GCM authentication tag.
    public let tag: Data

    /// Encrypted content bytes.
    public let ciphertext: Data

    /// Create an artifact from its constituent parts.
    public init(iv: Data, tag: Data, ciphertext: Data) {
        self.iv = iv
        self.tag = tag
        self.ciphertext = ciphertext
    }

    /// Parse a raw `.veu` blob into a `VeuArtifact`.
    /// - Throws: `VeuCryptoError.invalidArtifactFormat` when the data is too short.
    public init(from data: Data) throws {
        guard data.count >= VeuArtifact.headerSize else {
            throw VeuCryptoError.invalidArtifactFormat
        }
        let base = data.startIndex
        iv         = Data(data[base ..< base + 12])
        tag        = Data(data[base + 12 ..< base + 28])
        ciphertext = Data(data[base + 28 ..< data.endIndex])
    }

    /// Serialize the artifact back into raw bytes.
    public func serialized() -> Data {
        var out = Data(capacity: VeuArtifact.headerSize + ciphertext.count)
        out.append(iv)
        out.append(tag)
        out.append(ciphertext)
        return out
    }
}
