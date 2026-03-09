// SyncEngine.swift — Veu Protocol: Delta-Sync Orchestrator
//
// Implements the vector clock delta-sync protocol from SYNC.md.
// On connection: exchange clocks → calculate delta → push missing artifacts
// → receive acks → mark synced.  Also handles BurnNotice propagation.

import Foundation
import VeuAuth

/// Delegate for SyncEngine events.
public protocol SyncEngineDelegate: AnyObject {
    /// Called when an artifact has been received and stored in the Ledger.
    func syncEngine(_ engine: SyncEngine, didReceiveArtifact cid: String, circleID: String)

    /// Called when a burn notice has been processed.
    func syncEngine(_ engine: SyncEngine, didProcessBurn cid: String, circleID: String)

    /// Called when the sync session completes (all deltas exchanged).
    func syncEngine(_ engine: SyncEngine, didCompleteSyncWith peerDeviceID: String)

    /// Called when the sync session encounters an error.
    func syncEngine(_ engine: SyncEngine, didFailWith error: VeuGhostError)
}

/// Delta-sync orchestrator for the Ghost Network.
///
/// Manages vector clocks per Circle and drives the sync protocol over
/// a `GhostConnection`.  Interacts with `Ledger` for artifact storage.
public final class SyncEngine {

    /// The local device ID (from `ledger_meta`).
    public let deviceID: String

    /// Vector clocks per Circle: `circleID → VectorClock`.
    public var clocks: [String: VectorClock]

    /// The Ledger for artifact CRUD.
    public let ledger: Ledger

    /// Delegate for sync events.
    public weak var delegate: SyncEngineDelegate?

    /// Create a SyncEngine.
    ///
    /// - Parameters:
    ///   - deviceID: This device's unique ID.
    ///   - ledger: The local artifact Ledger.
    ///   - clocks: Initial vector clocks (default: empty).
    public init(deviceID: String, ledger: Ledger, clocks: [String: VectorClock] = [:]) {
        self.deviceID = deviceID
        self.ledger = ledger
        self.clocks = clocks
    }

    // MARK: - Clock Management

    /// Get or create the vector clock for a Circle.
    public func clock(for circleID: String) -> VectorClock {
        clocks[circleID] ?? VectorClock()
    }

    /// Record a local artifact creation (increment our sequence in the Circle's clock).
    ///
    /// - Parameter circleID: The Circle the artifact belongs to.
    /// - Returns: The new sequence number.
    @discardableResult
    public func recordLocalArtifact(circleID: String) -> UInt64 {
        var vc = clock(for: circleID)
        let seq = vc.increment(deviceID)
        clocks[circleID] = vc
        return seq
    }

    // MARK: - Initiator Flow

    /// Initiate a sync session as the requesting peer.
    ///
    /// 1. Send our vector clock for the Circle
    /// 2. Receive the response (peer's clock + artifact count)
    /// 3. Receive each pushed artifact and store it
    /// 4. Send acks
    ///
    /// - Parameters:
    ///   - circleID: The Circle to sync.
    ///   - connection: The encrypted peer connection.
    public func initiateSync(circleID: String, connection: GhostConnection) {
        let request = GhostMessage.syncRequest(
            GhostMessage.SyncRequestPayload(
                deviceID: deviceID,
                vectorClock: clock(for: circleID),
                circleID: circleID
            )
        )

        connection.send(request) { [weak self] result in
            switch result {
            case .failure(let error):
                self?.delegate?.syncEngine(self!, didFailWith: error)
            case .success:
                self?.receiveArtifacts(circleID: circleID, connection: connection, remaining: nil)
            }
        }
    }

    // MARK: - Responder Flow

    /// Handle an incoming sync request as the responding peer.
    ///
    /// 1. Receive the initiator's vector clock
    /// 2. Calculate the delta
    /// 3. Send our response (our clock + count)
    /// 4. Push each missing artifact
    ///
    /// - Parameters:
    ///   - request: The received sync request payload.
    ///   - connection: The encrypted peer connection.
    public func handleSyncRequest(_ request: GhostMessage.SyncRequestPayload, connection: GhostConnection) {
        let circleID = request.circleID
        let localClock = clock(for: circleID)
        let delta = localClock.delta(from: request.vectorClock)

        print("[SyncEngine] handleSyncRequest from \(request.deviceID), localClock=\(localClock), peerClock=\(request.vectorClock), delta=\(delta)")

        // Collect artifacts to push
        var artifactsToPush: [GhostMessage.ArtifactPushPayload] = []
        if let details = try? ledger.listArtifactDetails(circleID: circleID) {
            print("[SyncEngine] Local artifacts for circle \(String(circleID.prefix(8)))…: \(details.count)")
            for detail in details {
                let payload = GhostMessage.ArtifactPushPayload(
                    cid: detail.cid,
                    circleID: circleID,
                    artifactType: detail.artifactType,
                    encryptedMeta: detail.encryptedMeta,
                    sequence: localClock.sequence(for: deviceID),
                    originDeviceID: deviceID,
                    burnAfter: detail.burnAfter
                )
                artifactsToPush.append(payload)
            }
        }

        // Filter by delta: only push what the peer is missing
        let missingFromPeers = Set(delta.keys)
        let filtered = missingFromPeers.isEmpty ? artifactsToPush : artifactsToPush.filter { art in
            missingFromPeers.contains(art.originDeviceID)
        }

        print("[SyncEngine] Pushing \(filtered.count) artifacts to \(request.deviceID)")

        let response = GhostMessage.syncResponse(
            GhostMessage.SyncResponsePayload(
                deviceID: deviceID,
                vectorClock: localClock,
                artifactCount: filtered.count
            )
        )

        connection.send(response) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result {
                self.delegate?.syncEngine(self, didFailWith: error)
                return
            }
            self.pushArtifacts(filtered, connection: connection, circleID: circleID, peerDeviceID: request.deviceID)
        }

        // Merge the peer's clock into ours
        var mergedClock = localClock
        mergedClock.merge(request.vectorClock)
        clocks[circleID] = mergedClock
    }

    // MARK: - Burn Propagation

    /// Send a burn notice to a connected peer.
    ///
    /// - Parameters:
    ///   - cid: The CID of the artifact to burn.
    ///   - circleID: The Circle the artifact belongs to.
    ///   - connection: The peer connection.
    public func sendBurnNotice(cid: String, circleID: String, connection: GhostConnection) {
        let notice = GhostMessage.burnNotice(
            GhostMessage.BurnNoticePayload(cid: cid, circleID: circleID, originDeviceID: deviceID)
        )
        connection.send(notice) { _ in }
    }

    /// Handle a received burn notice.
    ///
    /// - Parameter payload: The burn notice from a peer.
    public func handleBurnNotice(_ payload: GhostMessage.BurnNoticePayload) {
        do {
            try ledger.purgeArtifact(cid: payload.cid)
            delegate?.syncEngine(self, didProcessBurn: payload.cid, circleID: payload.circleID)
        } catch {
            delegate?.syncEngine(self, didFailWith: .syncFailed("Burn failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Private

    private func receiveArtifacts(circleID: String, connection: GhostConnection, remaining: Int?) {
        connection.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.delegate?.syncEngine(self, didFailWith: error)

            case .success(let message):
                switch message {
                case .syncResponse(let response):
                    // Now we know how many artifacts to expect
                    if response.artifactCount == 0 {
                        // Merge their clock and finish
                        var vc = self.clock(for: circleID)
                        vc.merge(response.vectorClock)
                        self.clocks[circleID] = vc
                        self.delegate?.syncEngine(self, didCompleteSyncWith: response.deviceID)
                    } else {
                        self.receiveArtifacts(circleID: circleID, connection: connection, remaining: response.artifactCount)
                    }

                case .artifactPush(let artifact):
                    self.storeReceivedArtifact(artifact)
                    let newRemaining = (remaining ?? 1) - 1
                    if newRemaining > 0 {
                        self.receiveArtifacts(circleID: circleID, connection: connection, remaining: newRemaining)
                    } else {
                        self.delegate?.syncEngine(self, didCompleteSyncWith: "peer")
                    }

                case .burnNotice(let burn):
                    self.handleBurnNotice(burn)

                default:
                    break
                }
            }
        }
    }

    /// Store a received artifact (called from GhostNode for direct push handling).
    public func storeReceivedArtifactPublic(_ artifact: GhostMessage.ArtifactPushPayload) {
        storeReceivedArtifact(artifact)
    }

    private func storeReceivedArtifact(_ artifact: GhostMessage.ArtifactPushPayload) {
        print("[SyncEngine] Storing artifact \(String(artifact.cid.prefix(8)))… for circle \(String(artifact.circleID.prefix(8)))…")
        do {
            try ledger.insertArtifact(
                cid: artifact.cid,
                circleID: artifact.circleID,
                artifactType: artifact.artifactType,
                encryptedMeta: artifact.encryptedMeta,
                burnAfter: artifact.burnAfter
            )
            try ledger.markSynced(cid: artifact.cid)
            print("[SyncEngine] ✅ Stored artifact \(String(artifact.cid.prefix(8)))…")
            delegate?.syncEngine(self, didReceiveArtifact: artifact.cid, circleID: artifact.circleID)
        } catch let error as VeuAuthError {
            // UNIQUE constraint = artifact already exists — skip silently
            if case .ledgerError(let msg) = error, msg.contains("UNIQUE constraint") {
                print("[SyncEngine] ⏭️ Artifact \(String(artifact.cid.prefix(8)))… already exists, skipping")
            } else {
                print("[SyncEngine] ❌ Store failed: \(error)")
                delegate?.syncEngine(self, didFailWith: .syncFailed("Store failed: \(error.localizedDescription)"))
                return
            }
        } catch {
            print("[SyncEngine] ❌ Store failed: \(error)")
            delegate?.syncEngine(self, didFailWith: .syncFailed("Store failed: \(error.localizedDescription)"))
            return
        }

        // Update the vector clock for the origin device
        var vc = clock(for: artifact.circleID)
        let currentSeq = vc.sequence(for: artifact.originDeviceID)
        if artifact.sequence > currentSeq {
            vc.set(artifact.originDeviceID, to: artifact.sequence)
            clocks[artifact.circleID] = vc
        }
    }

    /// Push artifacts to a peer (called from GhostNode for direct push).
    public func pushArtifactsPublic(_ artifacts: [GhostMessage.ArtifactPushPayload],
                                     connection: GhostConnection,
                                     circleID: String,
                                     peerDeviceID: String) {
        pushArtifacts(artifacts, connection: connection, circleID: circleID, peerDeviceID: peerDeviceID)
    }

    private func pushArtifacts(_ artifacts: [GhostMessage.ArtifactPushPayload],
                               connection: GhostConnection,
                               circleID: String,
                               peerDeviceID: String) {
        guard let first = artifacts.first else {
            delegate?.syncEngine(self, didCompleteSyncWith: peerDeviceID)
            return
        }

        connection.send(.artifactPush(first)) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result {
                self.delegate?.syncEngine(self, didFailWith: error)
                return
            }
            let rest = Array(artifacts.dropFirst())
            self.pushArtifacts(rest, connection: connection, circleID: circleID, peerDeviceID: peerDeviceID)
        }
    }
}
