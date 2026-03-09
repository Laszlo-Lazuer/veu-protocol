// DeadLink.swift — Veu Protocol: Ephemeral Invitation Links
//
// A Dead Link is a one-time-use, time-limited invitation URI for initiating
// an Emerald Handshake.  It encodes the initiator's ephemeral public key,
// a session identifier, an expiry timestamp, and an Ed25519 signature.
//
// URI format: veu://handshake?id=<uuid>&pk=<base64url>&exp=<unix>&sig=<base64url>

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A one-time-use, time-limited invitation for an Emerald Handshake.
///
/// The Dead Link encodes everything a responding peer needs to begin the
/// key exchange:
/// - A session identifier (`id`) to correlate the handshake.
/// - The initiator's ephemeral X25519 public key (`pk`) for ECDH.
/// - An expiry Unix timestamp (`exp`).
/// - An Ed25519 signature (`sig`) proving the initiator created this link.
///
/// Dead Links are designed to self-destruct: they expire after a configurable
/// TTL (default 5 minutes) and can only be consumed once.
public struct DeadLink {

    // MARK: - Constants

    /// Default Time-To-Live for a Dead Link, in seconds (5 minutes).
    public static let defaultTTL: TimeInterval = 300

    /// The URI scheme and host used by Veu handshake links.
    public static let scheme = "veu"
    public static let host = "handshake"

    // MARK: - Properties

    /// Unique session identifier for this handshake invitation.
    public let id: UUID

    /// The initiator's ephemeral X25519 public key (raw 32 bytes).
    public let publicKey: Curve25519.KeyAgreement.PublicKey

    /// Unix timestamp (seconds) after which this link is dead.
    public let expiry: Int

    /// Ed25519 signature over the canonical payload `id|pk|exp`.
    public let signature: Data

    // MARK: - Generation

    /// Generate a new Dead Link signed by the provided Ed25519 signing key.
    ///
    /// - Parameters:
    ///   - keyAgreementPublicKey: The ephemeral X25519 public key to advertise.
    ///   - signingKey: The Ed25519 private key used to sign the link.
    ///   - ttl: Time-to-live in seconds (default: 5 minutes).
    /// - Returns: A fully signed `DeadLink` ready for URI encoding.
    public static func generate(
        keyAgreementPublicKey: Curve25519.KeyAgreement.PublicKey,
        signingKey: Curve25519.Signing.PrivateKey,
        ttl: TimeInterval = DeadLink.defaultTTL
    ) throws -> DeadLink {
        let sessionID = UUID()
        let expiry = Int(Date().timeIntervalSince1970) + Int(ttl)

        let payload = DeadLink.canonicalPayload(
            id: sessionID,
            publicKeyData: keyAgreementPublicKey.rawRepresentation,
            expiry: expiry
        )

        let signature = try signingKey.signature(for: payload)

        return DeadLink(
            id: sessionID,
            publicKey: keyAgreementPublicKey,
            expiry: expiry,
            signature: Data(signature)
        )
    }

    // MARK: - URI Encoding

    /// Encode this Dead Link as a `veu://handshake?…` URI string.
    public func toURI() -> String {
        let pkBase64 = publicKey.rawRepresentation.base64URLEncoded()
        let sigBase64 = signature.base64URLEncoded()
        return "\(DeadLink.scheme)://\(DeadLink.host)?id=\(id.uuidString)&pk=\(pkBase64)&exp=\(expiry)&sig=\(sigBase64)"
    }

    // MARK: - URI Parsing

    /// Parse and validate a Dead Link from a URI string.
    ///
    /// - Parameter uri: The full `veu://handshake?…` URI string.
    /// - Throws: `VeuAuthError.deadLinkInvalid` if the URI is malformed.
    /// - Returns: A parsed `DeadLink` (expiry and signature are NOT checked here).
    public static func parse(uri: String) throws -> DeadLink {
        guard let components = URLComponents(string: uri),
              components.scheme == DeadLink.scheme,
              components.host == DeadLink.host,
              let queryItems = components.queryItems else {
            throw VeuAuthError.deadLinkInvalid
        }

        guard let idStr = queryItems.first(where: { $0.name == "id" })?.value,
              let sessionID = UUID(uuidString: idStr),
              let pkStr = queryItems.first(where: { $0.name == "pk" })?.value,
              let pkData = Data(base64URLEncoded: pkStr),
              let expStr = queryItems.first(where: { $0.name == "exp" })?.value,
              let expiry = Int(expStr),
              let sigStr = queryItems.first(where: { $0.name == "sig" })?.value,
              let sigData = Data(base64URLEncoded: sigStr) else {
            throw VeuAuthError.deadLinkInvalid
        }

        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pkData) else {
            throw VeuAuthError.deadLinkInvalid
        }

        return DeadLink(
            id: sessionID,
            publicKey: publicKey,
            expiry: expiry,
            signature: sigData
        )
    }

    // MARK: - Validation

    /// Check whether this Dead Link has expired relative to the given date.
    public func isExpired(at date: Date = Date()) -> Bool {
        return Int(date.timeIntervalSince1970) >= expiry
    }

    /// Verify the Ed25519 signature on this Dead Link.
    ///
    /// - Parameter signingPublicKey: The Ed25519 public key of the initiator.
    /// - Throws: `VeuAuthError.signatureInvalid` if verification fails.
    public func verify(signingPublicKey: Curve25519.Signing.PublicKey) throws {
        let payload = DeadLink.canonicalPayload(
            id: id,
            publicKeyData: publicKey.rawRepresentation,
            expiry: expiry
        )

        guard signingPublicKey.isValidSignature(signature, for: payload) else {
            throw VeuAuthError.signatureInvalid
        }
    }

    /// Validate expiry and signature in one call.
    ///
    /// - Parameter signingPublicKey: The Ed25519 public key of the initiator.
    /// - Throws: `VeuAuthError.deadLinkExpired` or `.signatureInvalid`.
    public func validate(signingPublicKey: Curve25519.Signing.PublicKey, at date: Date = Date()) throws {
        guard !isExpired(at: date) else {
            throw VeuAuthError.deadLinkExpired
        }
        try verify(signingPublicKey: signingPublicKey)
    }

    // MARK: - Internal

    /// Canonical byte payload for signing: `id_bytes | pk_bytes | exp_bytes`.
    static func canonicalPayload(id: UUID, publicKeyData: Data, expiry: Int) -> Data {
        var data = Data()
        // UUID string as UTF-8 (deterministic)
        data.append(Data(id.uuidString.utf8))
        // Raw X25519 public key bytes
        data.append(publicKeyData)
        // Expiry as decimal string UTF-8
        data.append(Data(String(expiry).utf8))
        return data
    }
}

// MARK: - Equatable

extension DeadLink: Equatable {
    public static func == (lhs: DeadLink, rhs: DeadLink) -> Bool {
        return lhs.id == rhs.id
            && lhs.publicKey.rawRepresentation == rhs.publicKey.rawRepresentation
            && lhs.expiry == rhs.expiry
            && lhs.signature == rhs.signature
    }
}

// MARK: - Base64URL Helpers

extension Data {
    /// Encode to Base64URL (RFC 4648 §5) — no padding.
    public func base64URLEncoded() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode from Base64URL (RFC 4648 §5).
    public init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-add padding
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
