import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Ghost identity for a device: signing keypair + derived callsign + Aura seed.
public struct Identity: Codable, Equatable {

    /// Ed25519 signing public key (raw 32 bytes, hex-encoded for Codable).
    public let publicKeyHex: String

    /// Ed25519 signing private key (raw 32 bytes, hex-encoded for Codable).
    public let privateKeyHex: String

    /// Human-readable callsign: first 8 hex chars of HMAC-SHA-256(pubkey, "veu-callsign-v1").
    public let callsign: String

    /// Deterministic Aura seed color derived from public key.
    public let auraSeedR: Float
    public let auraSeedG: Float
    public let auraSeedB: Float

    /// Device ID used as vector clock key (first 16 hex chars of pubkey hash).
    public let deviceID: String

    // MARK: - Transient (non-Codable) accessors

    /// Reconstruct the Ed25519 signing private key from stored hex.
    public var signingPrivateKey: Curve25519.Signing.PrivateKey {
        get throws {
            guard let data = Data(hexString: privateKeyHex) else {
                throw VeuAppError.identityCorrupted
            }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
    }

    /// Reconstruct the Ed25519 signing public key from stored hex.
    public var signingPublicKey: Curve25519.Signing.PublicKey {
        get throws {
            guard let data = Data(hexString: publicKeyHex) else {
                throw VeuAppError.identityCorrupted
            }
            return try Curve25519.Signing.PublicKey(rawRepresentation: data)
        }
    }

    /// Aura seed as SIMD3 for shader uniforms.
    public var auraSeed: (r: Float, g: Float, b: Float) {
        (auraSeedR, auraSeedG, auraSeedB)
    }

    // MARK: - Generation

    /// Generate a fresh identity with a random Ed25519 keypair.
    public static func generate() -> Identity {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let pubData = publicKey.rawRepresentation

        let callsign = Self.deriveCallsign(from: pubData)
        let aura = Self.deriveAuraColor(from: pubData)
        let deviceID = Self.deriveDeviceID(from: pubData)

        return Identity(
            publicKeyHex: pubData.hexString,
            privateKeyHex: privateKey.rawRepresentation.hexString,
            callsign: callsign,
            auraSeedR: aura.r,
            auraSeedG: aura.g,
            auraSeedB: aura.b,
            deviceID: deviceID
        )
    }

    // MARK: - Derivation helpers

    /// Callsign: first 8 hex chars of HMAC-SHA-256(pubkey, "veu-callsign-v1").
    public static func deriveCallsign(from publicKeyData: Data) -> String {
        let key = SymmetricKey(data: publicKeyData)
        let tag = HMAC<SHA256>.authenticationCode(
            for: Data("veu-callsign-v1".utf8),
            using: key
        )
        return Data(tag).prefix(4).hexString.uppercased()
    }

    /// Aura color: RGB from first 3 bytes of HMAC-SHA-256(pubkey, "aura-color").
    public static func deriveAuraColor(from publicKeyData: Data) -> (r: Float, g: Float, b: Float) {
        let key = SymmetricKey(data: publicKeyData)
        let tag = HMAC<SHA256>.authenticationCode(
            for: Data("aura-color".utf8),
            using: key
        )
        let bytes = Array(Data(tag))
        return (
            r: Float(bytes[0]) / 255.0,
            g: Float(bytes[1]) / 255.0,
            b: Float(bytes[2]) / 255.0
        )
    }

    /// Device ID: first 16 hex chars of SHA-256(pubkey).
    public static func deriveDeviceID(from publicKeyData: Data) -> String {
        let hash = SHA256.hash(data: publicKeyData)
        return Data(hash).prefix(8).hexString
    }
}

// MARK: - Data hex helpers

extension Data {
    /// Hex-encode data to lowercase string.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Decode hex string to Data. Returns nil if invalid hex.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
}
