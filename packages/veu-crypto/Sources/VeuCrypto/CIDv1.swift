// CIDv1.swift — Veu Protocol: Content Identifier Generation
//
// Implements IPFS-compatible CIDv1 content addressing:
//   SHA-256(data) → multihash → CIDv1 (base32lower, dag-pb codec)
//
// This allows artifacts to be globally unique and content-verifiable.
// Future-compatible with full IPFS integration (Kubo) without changing IDs.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// IPFS-compatible CIDv1 content identifier generation.
///
/// A CID (Content Identifier) uniquely identifies a piece of content by its hash.
/// Format: `<multibase-prefix><version><codec><multihash>`
///
/// - Multibase: base32lower (`b`)
/// - Version: CIDv1 (`0x01`)
/// - Codec: raw (`0x55`) — opaque encrypted blob
/// - Multihash: SHA-256 (`0x12`, length `0x20`)
///
/// Example: `bafkreihdwdcefg...`
public enum CIDv1 {

    // MARK: - Constants

    /// CIDv1 version byte.
    private static let version: UInt8 = 0x01

    /// Multicodec for raw binary (`0x55`).
    private static let rawCodec: UInt8 = 0x55

    /// Multihash function code for SHA-256 (`0x12`).
    private static let sha256Code: UInt8 = 0x12

    /// SHA-256 digest length in bytes.
    private static let sha256Length: UInt8 = 0x20

    // MARK: - Public API

    /// Generate a CIDv1 from raw data.
    ///
    /// - Parameter data: The content to hash (typically plaintext before encryption).
    /// - Returns: A base32lower-encoded CIDv1 string (e.g., `bafkrei...`).
    public static func generate(from data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return encodeCID(digest: Data(digest))
    }

    /// Generate a CIDv1 from a pre-computed SHA-256 digest.
    ///
    /// - Parameter digest: A 32-byte SHA-256 hash.
    /// - Returns: A base32lower-encoded CIDv1 string.
    public static func generate(fromDigest digest: Data) -> String {
        precondition(digest.count == 32, "SHA-256 digest must be 32 bytes")
        return encodeCID(digest: digest)
    }

    /// Validate whether a string is a well-formed CIDv1.
    ///
    /// - Parameter cid: The candidate CID string.
    /// - Returns: `true` if the string decodes to a valid CIDv1 with SHA-256.
    public static func isValid(_ cid: String) -> Bool {
        guard cid.hasPrefix("b"), cid.count > 10 else { return false }
        let encoded = String(cid.dropFirst()) // strip multibase prefix
        guard let bytes = base32Decode(encoded) else { return false }
        guard bytes.count >= 4 else { return false }
        return bytes[0] == version
            && bytes[1] == rawCodec
            && bytes[2] == sha256Code
            && bytes[3] == sha256Length
            && bytes.count == 4 + Int(sha256Length)
    }

    /// Extract the SHA-256 digest from a CIDv1 string.
    ///
    /// - Parameter cid: A valid CIDv1 string.
    /// - Returns: The 32-byte SHA-256 digest, or `nil` if the CID is invalid.
    public static func extractDigest(from cid: String) -> Data? {
        guard cid.hasPrefix("b"), cid.count > 10 else { return nil }
        let encoded = String(cid.dropFirst())
        guard let bytes = base32Decode(encoded) else { return nil }
        guard bytes.count == 4 + Int(sha256Length),
              bytes[0] == version,
              bytes[1] == rawCodec,
              bytes[2] == sha256Code,
              bytes[3] == sha256Length else { return nil }
        return Data(bytes[4...])
    }

    // MARK: - Internal

    private static func encodeCID(digest: Data) -> String {
        // CID binary: version(1) + codec(1) + hash-fn(1) + hash-len(1) + digest(32)
        var cidBytes = Data(capacity: 4 + digest.count)
        cidBytes.append(version)
        cidBytes.append(rawCodec)
        cidBytes.append(sha256Code)
        cidBytes.append(sha256Length)
        cidBytes.append(digest)
        return "b" + base32Encode(cidBytes)
    }

    // MARK: - Base32 (RFC 4648, lowercase, no padding)

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    private static func base32Encode(_ data: Data) -> String {
        var result = ""
        result.reserveCapacity((data.count * 8 + 4) / 5)

        var buffer: UInt64 = 0
        var bits = 0

        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = Int((buffer >> bits) & 0x1F)
                result.append(alphabet[index])
            }
        }

        if bits > 0 {
            let index = Int((buffer << (5 - bits)) & 0x1F)
            result.append(alphabet[index])
        }

        return result
    }

    private static let decodeTable: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() {
            table[c] = UInt8(i)
        }
        return table
    }()

    private static func base32Decode(_ string: String) -> Data? {
        var buffer: UInt64 = 0
        var bits = 0
        var result = Data()
        result.reserveCapacity(string.count * 5 / 8)

        for char in string {
            guard let value = decodeTable[char] else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((buffer >> bits) & 0xFF))
            }
        }

        return result
    }
}
