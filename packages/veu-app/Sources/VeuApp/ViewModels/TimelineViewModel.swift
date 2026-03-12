import Foundation
import VeuAuth
import VeuCrypto
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Represents a single artifact in the timeline.
public struct TimelineEntry: Equatable {
    public let cid: String
    public let artifactType: String
    public let glazeSeedColor: (r: Float, g: Float, b: Float)
    public let burnAfter: Int?
    /// In-memory plaintext for reveal (POC only — never persisted).
    public let plaintextData: Data?
    /// Device ID of the sender.
    public let senderID: String?
    /// Sender's callsign for display.
    public let senderCallsign: String?
    /// Target recipients (nil = everyone in circle, [] = public).
    public let targetRecipients: [String]?
    /// Whether this is a targeted post (not for everyone).
    public var isTargeted: Bool { targetRecipients != nil && targetRecipients?.isEmpty == false }
    /// Whether the current user can view this content.
    public let canReveal: Bool

    public static func == (lhs: TimelineEntry, rhs: TimelineEntry) -> Bool {
        lhs.cid == rhs.cid
    }
}

/// Manages the artifact timeline for the active circle.
public final class TimelineViewModel {

    // MARK: - State

    /// Artifacts in the active circle's timeline.
    public private(set) var entries: [TimelineEntry] = []

    /// Last error encountered.
    public private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let appState: AppState

    // MARK: - Init

    public init(appState: AppState) {
        self.appState = appState
    }

    /// In-memory cache of plaintext data keyed by CID (POC only).
    private var plaintextCache: [String: Data] = [:]

    // MARK: - Timeline

    /// Reload the artifact list from the Ledger for the active circle.
    public func reload() throws {
        guard let circleID = appState.activeCircleID,
              let circleKey = appState.circleKeys[circleID] else {
            entries = []
            return
        }
        
        let myDeviceID = appState.identity.deviceID

        let details = try appState.ledger.listArtifactDetails(circleID: circleID)
        entries = details.map { detail in
            let seedData = GlazeSeed.glazeSeed(
                from: Data(detail.cid.utf8),
                salt: circleKey.glazeSalt
            )
            let color = GlazeSeed.glazeColor(from: seedData)
            
            // Determine if user can reveal this content
            let canReveal: Bool
            if let targets = detail.targetRecipients, !targets.isEmpty {
                // Targeted post: can reveal if sender or recipient
                canReveal = detail.senderID == myDeviceID || targets.contains(myDeviceID)
            } else {
                // Public post: everyone can reveal
                canReveal = true
            }
            
            // Look up sender callsign from circle members (or use fallback)
            let senderCallsign: String? = detail.senderID.flatMap { senderID in
                if senderID == myDeviceID {
                    return appState.identity.callsign
                }
                // Try to look up from circle members
                if let members = try? appState.ledger.listCircleMembers(circleID: circleID),
                   let member = members.first(where: { $0.deviceID == senderID }) {
                    return member.callsign
                }
                return nil
            }

            // Use cached plaintext or decrypt from encryptedMeta (only if canReveal)
            let plaintext: Data? = canReveal ? (plaintextCache[detail.cid] ?? {
                guard !detail.encryptedMeta.isEmpty else { return nil }
                do {
                    let artifact = try VeuArtifact(from: detail.encryptedMeta)
                    return try Scramble.unscramble(artifact: artifact, using: circleKey.symmetricKey)
                } catch {
                    return nil
                }
            }()) : nil

            return TimelineEntry(
                cid: detail.cid,
                artifactType: detail.artifactType,
                glazeSeedColor: color,
                burnAfter: detail.burnAfter,
                plaintextData: plaintext,
                senderID: detail.senderID,
                senderCallsign: senderCallsign,
                targetRecipients: detail.targetRecipients,
                canReveal: canReveal
            )
        }
    }

    // MARK: - Compose

    /// Encrypt data and insert into the Ledger as a new artifact.
    /// Returns the CID and the encrypted artifact for sync.
    @discardableResult
    public func compose(
        data: Data,
        artifactType: String = "post",
        targetRecipients: [String]? = nil,
        burnAfter: Int? = nil
    ) throws -> (cid: String, artifact: VeuArtifact, encryptedMeta: Data) {
        let circleKey = try appState.activeCircleKey()
        guard let circleID = appState.activeCircleID else {
            throw VeuAppError.noActiveCircle
        }
        
        let senderID = appState.identity.deviceID

        let cid = UUID().uuidString
        // POC: encrypt directly with circle key so synced peers can decrypt
        let artifact = try Scramble.scramble(data: data, using: circleKey.symmetricKey)
        let encryptedMeta = artifact.serialized()
        
        // Encode target recipients as JSON if present
        let targetRecipientsJSON: String? = targetRecipients.flatMap { recipients in
            guard !recipients.isEmpty else { return nil }
            return try? String(data: JSONEncoder().encode(recipients), encoding: .utf8)
        }

        _ = try appState.ledger.insertArtifact(
            cid: cid,
            circleID: circleID,
            artifactType: artifactType,
            encryptedMeta: encryptedMeta,
            senderID: senderID,
            targetRecipients: targetRecipientsJSON,
            wrappedKeys: nil,  // TODO: add ephemeral key wrapping for targeted posts
            burnAfter: burnAfter
        )

        // Cache plaintext for in-app reveal (POC only)
        plaintextCache[cid] = data

        try reload()
        return (cid: cid, artifact: artifact, encryptedMeta: encryptedMeta)
    }

    /// Decrypt an artifact from the Ledger by CID.
    public func reveal(cid: String, artifactKey: SymmetricKey) throws -> Data {
        // In a full app, the encrypted data would be fetched from local storage.
        // For the POC, we reconstruct from the Ledger's encryptedMeta.
        guard let circleID = appState.activeCircleID else {
            throw VeuAppError.noActiveCircle
        }

        let cids = try appState.ledger.listArtifacts(circleID: circleID)
        guard cids.contains(cid) else {
            throw VeuAppError.artifactNotFound(cid)
        }

        // The actual decryption would use the stored ciphertext;
        // for now this demonstrates the Scramble.unscramble path exists.
        throw VeuAppError.decryptionFailed("Full reveal requires artifact blob storage (post-POC)")
    }

    // MARK: - Burn

    /// Purge an artifact from the Ledger.
    public func burn(cid: String) throws {
        try appState.ledger.purgeArtifact(cid: cid)
        try reload()
    }

    /// Purge all expired artifacts.
    public func burnExpired() throws {
        let expired = try appState.ledger.expiredArtifacts()
        for cid in expired {
            try appState.ledger.purgeArtifact(cid: cid)
        }
        if !expired.isEmpty {
            try reload()
        }
    }
}
