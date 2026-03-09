// MeshNode.swift — Veu Protocol: Multi-Transport Mesh Coordinator
//
// Orchestrates all three transports (Local > Mesh > Global) and forwards
// established connections to the underlying GhostNode for delta-sync.
// The MeshNode is the primary entry point for the app's NetworkService.

import Foundation
import VeuAuth
import VeuGhost

/// Delegate for MeshNode events.
public protocol MeshNodeDelegate: AnyObject {
    /// Called when the active transport changes.
    func meshNode(_ node: MeshNode, didChangeActiveTransport name: String)

    /// Called when a peer connects via any transport.
    func meshNode(_ node: MeshNode, didConnectPeer peerID: String, via transport: String)

    /// Called when a peer disconnects.
    func meshNode(_ node: MeshNode, didDisconnectPeer peerID: String)

    /// Called when an artifact is received.
    func meshNode(_ node: MeshNode, didReceiveArtifact cid: String, circleID: String)

    /// Called when a burn notice is processed.
    func meshNode(_ node: MeshNode, didProcessBurn cid: String, circleID: String)

    /// Called when sync completes with a peer.
    func meshNode(_ node: MeshNode, didCompleteSyncWith peerID: String)

    /// Called when an error occurs.
    func meshNode(_ node: MeshNode, didFailWith error: Error)
}

/// Multi-transport mesh coordinator for the Ghost Network.
///
/// Manages three transport layers simultaneously:
/// 1. **Local** (LAN/mDNS): Highest priority — same Wi-Fi / AWDL
/// 2. **Mesh** (Bluetooth LE + AWDL): Medium priority — offline proximity relay
/// 3. **Global** (WebSocket relay): Lowest priority — internet sync
///
/// All transports feed into a single `GhostNode` which handles delta-sync.
public final class MeshNode {

    // MARK: - Public Properties

    /// The underlying GhostNode (for SyncEngine access).
    public let ghostNode: GhostNode

    /// Active transports.
    public private(set) var transports: [any MeshTransportProtocol] = []

    /// The currently active (highest priority connected) transport name.
    public var activeTransportName: String? {
        transports.first(where: { $0.isAvailable })?.name
    }

    /// Whether any transport is currently active.
    public var isRunning: Bool {
        transports.contains(where: { $0.isAvailable })
    }

    /// Delegate for mesh events.
    public weak var delegate: MeshNodeDelegate?

    // MARK: - Configuration

    /// The Circle being synced.
    public let circleID: String

    /// Optional relay server URL for GlobalTransport.
    public let relayURL: URL?

    // MARK: - Internal

    private let circleKey: Data
    private let deviceID: String
    private let queue: DispatchQueue

    /// Create a MeshNode for a Circle.
    ///
    /// - Parameters:
    ///   - deviceID: This device's unique ID.
    ///   - circleID: The Circle to sync.
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - ledger: The local artifact Ledger.
    ///   - relayURL: Optional relay server URL (nil disables GlobalTransport).
    ///   - deviceName: Human-readable device name for Bluetooth mesh.
    public init(deviceID: String, circleID: String, circleKey: Data,
                ledger: Ledger, relayURL: URL? = nil, deviceName: String = "Veu") {
        self.deviceID = deviceID
        self.circleID = circleID
        self.circleKey = circleKey
        self.relayURL = relayURL
        self.queue = DispatchQueue(label: "veu.mesh.\(circleID)", qos: .userInitiated)
        self.ghostNode = GhostNode(deviceID: deviceID, circleID: circleID, circleKey: circleKey, ledger: ledger)
    }

    // MARK: - Lifecycle

    /// Start all available transports.
    ///
    /// - Throws: If no transports can be started.
    public func start() throws {
        // Wire up sync delegate
        ghostNode.syncDelegate = self

        // 1. Local transport (always available)
        let local = LocalTransport(circleKey: circleKey, queue: queue)
        local.delegate = self
        transports.append(local)

        // 2. Bluetooth/AWDL mesh
        let mesh = MeshTransport(circleKey: circleKey, deviceName: deviceID)
        mesh.delegate = self
        transports.append(mesh)

        // 3. Global relay (if configured)
        if let relayURL = relayURL {
            let global = GlobalTransport(relayURL: relayURL, circleKey: circleKey, deviceID: deviceID)
            global.delegate = self
            transports.append(global)
        }

        // Start all transports — failures are non-fatal (other transports may work)
        var started = false
        for transport in transports {
            do {
                try transport.start()
                started = true
                print("[MeshNode] Started transport: \(transport.name)")
            } catch {
                print("[MeshNode] Failed to start \(transport.name): \(error)")
            }
        }

        guard started else {
            throw VeuMeshError.noTransportAvailable
        }
    }

    /// Stop all transports and disconnect all peers.
    public func stop() {
        for transport in transports {
            transport.stop()
        }
        transports.removeAll()
        ghostNode.stop()
    }

    // MARK: - Sync Triggers

    /// Re-sync with all peers across all transports.
    public func resyncAllPeers() {
        ghostNode.resyncAllPeers()
    }

    /// Record a local artifact creation and push to all peers.
    @discardableResult
    public func recordLocalArtifact() -> UInt64 {
        let seq = ghostNode.syncEngine.recordLocalArtifact(circleID: circleID)
        resyncAllPeers()
        return seq
    }

    // MARK: - Push Token

    /// Register an APNs push token with the relay server.
    public func registerPushToken(_ token: String) {
        for transport in transports {
            if let global = transport as? GlobalTransport {
                global.pushToken = token
            }
        }
    }
}

// MARK: - MeshTransportDelegate

extension MeshNode: MeshTransportDelegate {
    public func transport(_ transport: any MeshTransportProtocol, didChangeState state: MeshTransportState) {
        if let activeName = activeTransportName {
            delegate?.meshNode(self, didChangeActiveTransport: activeName)
        }
    }

    public func transport(_ transport: any MeshTransportProtocol, didConnectPeer connection: any TransportConnection) {
        // Forward to GhostNode for sync
        ghostNode.acceptConnection(connection)
        delegate?.meshNode(self, didConnectPeer: connection.endpointDescription, via: transport.name)

        // Auto-initiate sync on outbound connections
        ghostNode.syncEngine.initiateSync(circleID: circleID, connection: connection)
    }

    public func transport(_ transport: any MeshTransportProtocol, didDisconnectPeer peerID: String) {
        delegate?.meshNode(self, didDisconnectPeer: peerID)
    }
}

// MARK: - SyncEngineDelegate

extension MeshNode: SyncEngineDelegate {
    public func syncEngine(_ engine: SyncEngine, didReceiveArtifact cid: String, circleID: String) {
        delegate?.meshNode(self, didReceiveArtifact: cid, circleID: circleID)
    }

    public func syncEngine(_ engine: SyncEngine, didProcessBurn cid: String, circleID: String) {
        delegate?.meshNode(self, didProcessBurn: cid, circleID: circleID)
    }

    public func syncEngine(_ engine: SyncEngine, didCompleteSyncWith peerDeviceID: String) {
        delegate?.meshNode(self, didCompleteSyncWith: peerDeviceID)
    }

    public func syncEngine(_ engine: SyncEngine, didFailWith error: VeuGhostError) {
        delegate?.meshNode(self, didFailWith: error)
    }
}
