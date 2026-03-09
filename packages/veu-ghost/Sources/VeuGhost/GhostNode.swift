// GhostNode.swift — Veu Protocol: Ghost Network Top-Level Coordinator
//
// Owns the LocalPulse (discovery) and SyncEngine (delta-sync), coordinating
// the full lifecycle: start → discover peers → connect → sync → stop.

import Foundation
import Network
import VeuAuth

/// Top-level coordinator for the Ghost Network.
///
/// Manages peer discovery via `LocalPulse` and artifact synchronization
/// via `SyncEngine`.  Start a node for each Circle the device participates in.
///
/// ```swift
/// let node = try GhostNode(deviceID: "abc", circleID: "xyz",
///                           circleKey: key, ledger: ledger)
/// try node.start()
/// ```
public final class GhostNode: @unchecked Sendable {

    /// The local device ID.
    public let deviceID: String

    /// The Circle this node is syncing.
    public let circleID: String

    /// The Circle's symmetric key.
    public let circleKey: Data

    /// The peer discovery service.
    public let pulse: LocalPulse

    /// The delta-sync engine.
    public let syncEngine: SyncEngine

    /// Active peer connections keyed by endpoint description.
    private var connections: [String: any TransportConnection] = [:]

    /// Pending artifact counts per connection key for direct push tracking.
    private var pendingArtifactCount: [String: Int] = [:]

    /// Dispatch queue for node operations.
    private let queue: DispatchQueue

    /// Delegate for sync events (forwarded from SyncEngine).
    public weak var syncDelegate: SyncEngineDelegate? {
        didSet { syncEngine.delegate = syncDelegate }
    }

    /// Whether the node is currently running.
    public private(set) var isRunning: Bool = false

    /// Create a GhostNode for a Circle.
    ///
    /// - Parameters:
    ///   - deviceID: This device's unique ID (from `ledger_meta`).
    ///   - circleID: The Circle to sync.
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - ledger: The local artifact Ledger.
    public init(deviceID: String, circleID: String, circleKey: Data, ledger: Ledger) {
        self.deviceID = deviceID
        self.circleID = circleID
        self.circleKey = circleKey
        self.queue = DispatchQueue(label: "veu.ghost.\(circleID)", qos: .userInitiated)
        self.pulse = LocalPulse(circleKey: circleKey, queue: queue)
        self.syncEngine = SyncEngine(deviceID: deviceID, ledger: ledger)
    }

    // MARK: - Lifecycle

    /// Start peer discovery and listen for incoming connections.
    ///
    /// - Throws: `VeuGhostError.discoveryFailed` if the listener cannot start.
    public func start() throws {
        guard !isRunning else { return }
        pulse.delegate = self
        try pulse.start()
        isRunning = true
    }

    /// Stop discovery and disconnect all peers.
    public func stop() {
        pulse.stop()
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        isRunning = false
    }

    // MARK: - Outbound Sync

    /// Manually trigger a sync with a discovered peer endpoint.
    ///
    /// - Parameter endpoint: The peer's NWEndpoint.
    public func connectAndSync(endpoint: NWEndpoint) {
        let conn = GhostConnection(endpoint: endpoint, circleKey: circleKey)
        let key = "\(endpoint)"
        connections[key] = conn

        conn.stateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.syncEngine.initiateSync(circleID: self.circleID, connection: conn)
            case .failed(_), .cancelled:
                self.connections.removeValue(forKey: key)
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    /// Re-sync with all currently connected peers (e.g., after sealing a new artifact).
    /// Since the sync protocol has the responder push to the initiator, we directly
    /// push our new artifacts and then ask the peer to sync back.
    public func resyncAllPeers() {
        print("[GhostNode] resyncAllPeers: \(connections.count) connections")
        guard let details = try? syncEngine.ledger.listArtifactDetails(circleID: circleID) else { return }
        let localClock = syncEngine.clock(for: circleID)

        let payloads = details.map { detail in
            GhostMessage.ArtifactPushPayload(
                cid: detail.cid,
                circleID: circleID,
                artifactType: detail.artifactType,
                encryptedMeta: detail.encryptedMeta,
                sequence: localClock.sequence(for: syncEngine.deviceID),
                originDeviceID: syncEngine.deviceID,
                burnAfter: detail.burnAfter
            )
        }

        for (key, conn) in connections {
            print("[GhostNode] Pushing \(payloads.count) artifacts to \(key)")
            let header = GhostMessage.syncResponse(
                GhostMessage.SyncResponsePayload(
                    deviceID: syncEngine.deviceID,
                    vectorClock: localClock,
                    artifactCount: payloads.count
                )
            )
            conn.send(header) { [weak self] result in
                guard let self = self else { return }
                if case .failure(let error) = result {
                    print("[GhostNode] Push header failed: \(error)")
                    return
                }
                self.syncEngine.pushArtifactsPublic(payloads, connection: conn, circleID: self.circleID, peerDeviceID: key)
            }
        }
    }
}

// MARK: - LocalPulseDelegate

extension GhostNode: LocalPulseDelegate {
    public func localPulse(_ pulse: LocalPulse, didDiscover endpoint: NWEndpoint, topicHash: String) {
        // Auto-connect to matching peers
        connectAndSync(endpoint: endpoint)
    }

    public func localPulse(_ pulse: LocalPulse, didLose endpoint: NWEndpoint) {
        let key = "\(endpoint)"
        connections[key]?.cancel()
        connections.removeValue(forKey: key)
    }

    public func localPulse(_ pulse: LocalPulse, didAcceptConnection connection: NWConnection) {
        let ghostConn = GhostConnection(connection: connection, circleKey: circleKey)
        acceptConnection(ghostConn)
    }
}

// MARK: - Transport-Agnostic Connection Handling

extension GhostNode {
    /// Accept any transport connection and begin listening for sync messages.
    ///
    /// This is the primary entry point for external transports (Bluetooth mesh,
    /// WebSocket relay) to hand off an established connection to the sync layer.
    public func acceptConnection(_ connection: any TransportConnection) {
        let key = connection.endpointDescription
        connections[key] = connection
        listenForMessages(on: connection, key: key)
    }

    private func listenForMessages(on conn: any TransportConnection, key: String) {
        conn.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(.syncRequest(let request)):
                print("[GhostNode] Received syncRequest from \(request.deviceID)")
                self.syncEngine.handleSyncRequest(request, connection: conn)
                self.listenForMessages(on: conn, key: key)

            case .success(.syncResponse(let response)):
                print("[GhostNode] Received syncResponse: \(response.artifactCount) artifacts incoming")
                if response.artifactCount == 0 {
                    var vc = self.syncEngine.clock(for: self.circleID)
                    vc.merge(response.vectorClock)
                    self.syncEngine.clocks[self.circleID] = vc
                    self.syncEngine.delegate?.syncEngine(self.syncEngine, didCompleteSyncWith: response.deviceID)
                } else {
                    self.pendingArtifactCount[key] = response.artifactCount
                }
                self.listenForMessages(on: conn, key: key)

            case .success(.artifactPush(let artifact)):
                print("[GhostNode] Received artifact push: \(String(artifact.cid.prefix(8)))…")
                self.syncEngine.storeReceivedArtifactPublic(artifact)
                let remaining = (self.pendingArtifactCount[key] ?? 1) - 1
                self.pendingArtifactCount[key] = remaining
                if remaining <= 0 {
                    self.pendingArtifactCount.removeValue(forKey: key)
                    self.syncEngine.delegate?.syncEngine(self.syncEngine, didCompleteSyncWith: "peer")
                }
                self.listenForMessages(on: conn, key: key)

            case .success(.burnNotice(let burn)):
                self.syncEngine.handleBurnNotice(burn)
                self.listenForMessages(on: conn, key: key)

            case .failure(let error):
                print("[GhostNode] Receive failed on \(key): \(error)")
                self.syncEngine.delegate?.syncEngine(self.syncEngine, didFailWith: error)
                self.connections.removeValue(forKey: key)

            default:
                self.listenForMessages(on: conn, key: key)
            }
        }
    }
}
