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
    private var connections: [String: GhostConnection] = [:]

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
        let key = ghostConn.endpointDescription
        connections[key] = ghostConn

        // Listen for the initiator's sync request
        ghostConn.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(.syncRequest(let request)):
                self.syncEngine.handleSyncRequest(request, connection: ghostConn)
            case .success(.burnNotice(let burn)):
                self.syncEngine.handleBurnNotice(burn)
            case .failure(let error):
                self.syncEngine.delegate?.syncEngine(self.syncEngine, didFailWith: error)
            default:
                break
            }
        }
    }
}
