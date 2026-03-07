// GhostMessage.swift — Veu Protocol: Ghost Network Protocol Messages
//
// Defines the message types exchanged between peers during delta-sync.
// All messages are JSON-encoded, then wrapped in an AES-256-GCM envelope
// using the Circle Key before transmission.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Protocol messages exchanged between Ghost Network peers.
///
/// Each message type maps to a step in the SYNC.md delta-sync protocol:
/// 1. Peers exchange `syncRequest` (containing their vector clocks)
/// 2. The responder sends `syncResponse` with the delta artifacts
/// 3. Individual artifacts are pushed via `artifactPush`
/// 4. Burn propagation uses `burnNotice`
/// 5. Each received artifact/burn is acknowledged with `ack`
public enum GhostMessage: Codable, Equatable {

    /// Step 1: Initiator sends its vector clock to request a delta.
    case syncRequest(SyncRequestPayload)

    /// Step 2: Responder sends artifacts the initiator is missing.
    case syncResponse(SyncResponsePayload)

    /// Step 3: Push a single artifact to a peer.
    case artifactPush(ArtifactPushPayload)

    /// Propagate a burn/purge event to peers.
    case burnNotice(BurnNoticePayload)

    /// Acknowledge receipt of an artifact or burn notice.
    case ack(AckPayload)

    // MARK: - Payloads

    public struct SyncRequestPayload: Codable, Equatable {
        /// The sender's device ID.
        public var deviceID: String
        /// The sender's current vector clock for this Circle.
        public var vectorClock: VectorClock
        /// The Circle being synced.
        public var circleID: String

        public init(deviceID: String, vectorClock: VectorClock, circleID: String) {
            self.deviceID = deviceID
            self.vectorClock = vectorClock
            self.circleID = circleID
        }
    }

    public struct SyncResponsePayload: Codable, Equatable {
        /// The responder's device ID.
        public var deviceID: String
        /// The responder's vector clock (so initiator can update).
        public var vectorClock: VectorClock
        /// Number of artifact pushes that will follow.
        public var artifactCount: Int

        public init(deviceID: String, vectorClock: VectorClock, artifactCount: Int) {
            self.deviceID = deviceID
            self.vectorClock = vectorClock
            self.artifactCount = artifactCount
        }
    }

    public struct ArtifactPushPayload: Codable, Equatable {
        /// IPFS CIDv1 (base32) content identifier.
        public var cid: String
        /// Circle this artifact belongs to.
        public var circleID: String
        /// Protocol-level artifact type (post, file, message, burn_notice).
        public var artifactType: String
        /// AES-256-GCM encrypted metadata blob (Base64-encoded for JSON transport).
        public var encryptedMeta: Data
        /// Sequence number assigned by the originating device.
        public var sequence: UInt64
        /// Originating device ID.
        public var originDeviceID: String
        /// Optional burn-after timestamp.
        public var burnAfter: Int?

        public init(cid: String, circleID: String, artifactType: String,
                    encryptedMeta: Data, sequence: UInt64, originDeviceID: String,
                    burnAfter: Int? = nil) {
            self.cid = cid
            self.circleID = circleID
            self.artifactType = artifactType
            self.encryptedMeta = encryptedMeta
            self.sequence = sequence
            self.originDeviceID = originDeviceID
            self.burnAfter = burnAfter
        }
    }

    public struct BurnNoticePayload: Codable, Equatable {
        /// CID of the artifact to purge.
        public var cid: String
        /// Circle the artifact belongs to.
        public var circleID: String
        /// Device that initiated the burn.
        public var originDeviceID: String

        public init(cid: String, circleID: String, originDeviceID: String) {
            self.cid = cid
            self.circleID = circleID
            self.originDeviceID = originDeviceID
        }
    }

    public struct AckPayload: Codable, Equatable {
        /// CID of the artifact or burn notice being acknowledged.
        public var cid: String
        /// Device sending the acknowledgement.
        public var deviceID: String

        public init(cid: String, deviceID: String) {
            self.cid = cid
            self.deviceID = deviceID
        }
    }

    // MARK: - Envelope Encryption

    /// Encrypt this message into an AES-256-GCM sealed envelope.
    ///
    /// Wire format: `nonce(12) || ciphertext || tag(16)`
    ///
    /// - Parameter circleKey: The 32-byte Circle symmetric key.
    /// - Returns: The encrypted envelope bytes.
    /// - Throws: `VeuGhostError.encryptionFailed` on failure.
    public func seal(with circleKey: Data) throws -> Data {
        let jsonData = try JSONEncoder().encode(self)
        let key = SymmetricKey(data: circleKey)
        do {
            let sealedBox = try AES.GCM.seal(jsonData, using: key)
            guard let combined = sealedBox.combined else {
                throw VeuGhostError.encryptionFailed("Failed to produce combined sealed box")
            }
            return combined
        } catch let error as VeuGhostError {
            throw error
        } catch {
            throw VeuGhostError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypt a sealed envelope back into a `GhostMessage`.
    ///
    /// - Parameters:
    ///   - envelope: The encrypted bytes (`nonce || ciphertext || tag`).
    ///   - circleKey: The 32-byte Circle symmetric key.
    /// - Returns: The decrypted `GhostMessage`.
    /// - Throws: `VeuGhostError.encryptionFailed` or `.decodingFailed`.
    public static func open(envelope: Data, with circleKey: Data) throws -> GhostMessage {
        let key = SymmetricKey(data: circleKey)
        let plaintext: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: envelope)
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw VeuGhostError.encryptionFailed(error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(GhostMessage.self, from: plaintext)
        } catch {
            throw VeuGhostError.decodingFailed(error.localizedDescription)
        }
    }
}
