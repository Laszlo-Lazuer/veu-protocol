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

        let details = try appState.ledger.listArtifactDetails(circleID: circleID)
        entries = details.map { detail in
            let seedData = GlazeSeed.glazeSeed(
                from: Data(detail.cid.utf8),
                salt: circleKey.glazeSalt
            )
            let color = GlazeSeed.glazeColor(from: seedData)

            // Use cached plaintext or decrypt from encryptedMeta
            let plaintext: Data? = plaintextCache[detail.cid] ?? {
                guard !detail.encryptedMeta.isEmpty else { return nil }
                do {
                    let artifact = try VeuArtifact(from: detail.encryptedMeta)
                    return try Scramble.unscramble(artifact: artifact, using: circleKey.symmetricKey)
                } catch {
                    return nil
                }
            }()

            return TimelineEntry(
                cid: detail.cid,
                artifactType: detail.artifactType,
                glazeSeedColor: color,
                burnAfter: detail.burnAfter,
                plaintextData: plaintext
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
        burnAfter: Int? = nil
    ) throws -> (cid: String, artifact: VeuArtifact, encryptedMeta: Data) {
        let circleKey = try appState.activeCircleKey()
        guard let circleID = appState.activeCircleID else {
            throw VeuAppError.noActiveCircle
        }

        let cid = UUID().uuidString
        // POC: encrypt directly with circle key so synced peers can decrypt
        let artifact = try Scramble.scramble(data: data, using: circleKey.symmetricKey)
        let encryptedMeta = artifact.serialized()

        _ = try appState.ledger.insertArtifact(
            cid: cid,
            circleID: circleID,
            artifactType: artifactType,
            encryptedMeta: encryptedMeta,
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
