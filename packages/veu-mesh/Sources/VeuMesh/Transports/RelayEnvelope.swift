// RelayEnvelope.swift — Veu Protocol: Cross-Circle Opaque Relay Wire Format
//
// Wire format for LoRa-style mesh relay through untrusted devices.
// Relay nodes see only the topic hash prefix (for routing) and an
// opaque encrypted blob.  They cannot determine sender, recipient,
// message type, or content.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Opaque relay envelope for cross-circle mesh forwarding.
///
/// Any Veu device can relay these envelopes without being a member
/// of the target circle.  The payload is AES-256-GCM sealed and
/// completely opaque to relay nodes.
///
/// ## Visible to relay nodes
/// - `topicPrefix`: 16-char HMAC hash — identifies the circle without revealing the key
/// - `ttl`: Hop counter for loop/flood prevention
/// - `relayTag`: Random per-message tag for dedup (not identifying)
/// - `timestamp`: Unix seconds for staleness rejection
/// - Blob size (implicit)
///
/// ## NOT visible to relay nodes
/// - Message content, type, sender, recipient, device IDs, circle key
public struct RelayEnvelope: Codable, Equatable {

    /// Topic hash prefix (first 16 chars of HMAC-SHA256(circleKey, "ghost-pulse-v1")).
    /// Relay nodes match this to peer subscription lists for routing.
    /// Cannot be reversed to derive the circle key.
    public let topicPrefix: String

    /// The sealed GhostMessage envelope (AES-256-GCM, opaque to relay).
    /// Includes the 4-byte length prefix used by all transports.
    public let payload: Data

    /// Time-to-live for multi-hop routing.  Decremented at each hop.
    /// Max 5 hops (same as MeshTransport).
    public let ttl: Int

    /// Random 8-byte hex tag, regenerated per message.
    /// Used by relay nodes for deduplication — not identifying.
    public let relayTag: String

    /// Unix timestamp (seconds since epoch) when the envelope was created.
    /// Relay nodes drop envelopes older than `maxAge`.
    public let timestamp: UInt64

    // MARK: - Constants

    /// Maximum relay hops.
    public static let maxTTL: Int = 5

    /// Maximum envelope age before relay nodes discard it (5 minutes).
    public static let maxAge: TimeInterval = 300

    // MARK: - Factory

    /// Create a relay envelope for an outbound message.
    ///
    /// - Parameters:
    ///   - payload: The sealed (encrypted) message frame including length prefix.
    ///   - circleKey: The circle key (used to derive topic prefix, not included in envelope).
    /// - Returns: A relay envelope ready for transmission.
    public static func wrap(payload: Data, circleKey: Data) -> RelayEnvelope {
        let topicHash = circleTopicHash(circleKey: circleKey)
        let tag = randomRelayTag()
        return RelayEnvelope(
            topicPrefix: String(topicHash.prefix(16)),
            payload: payload,
            ttl: maxTTL,
            relayTag: tag,
            timestamp: UInt64(Date().timeIntervalSince1970)
        )
    }

    /// Create a decremented copy for forwarding.
    public func forwarded() -> RelayEnvelope? {
        guard ttl > 0 else { return nil }
        return RelayEnvelope(
            topicPrefix: topicPrefix,
            payload: payload,
            ttl: ttl - 1,
            relayTag: relayTag,
            timestamp: timestamp
        )
    }

    /// Whether this envelope has expired.
    public var isExpired: Bool {
        let age = Date().timeIntervalSince1970 - Double(timestamp)
        return age > Self.maxAge
    }

    /// A dedup key derived from the payload (first 16 bytes of SHA-256).
    public var dedupKey: String {
        let hash = SHA256.hash(data: payload)
        return Data(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    /// Derive the topic hash from a circle key (same as GhostConnection.circleTopicHash).
    private static func circleTopicHash(circleKey: Data) -> String {
        let key = SymmetricKey(data: circleKey)
        let tag = HMAC<SHA256>.authenticationCode(for: Data("ghost-pulse-v1".utf8), using: key)
        return Data(tag).map { String(format: "%02x", $0) }.joined()
    }

    /// Generate a random 8-byte hex relay tag.
    private static func randomRelayTag() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
