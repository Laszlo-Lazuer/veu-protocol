import Foundation
import VeuAuth
import VeuCrypto
import VeuGhost
import VeuMesh
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Wraps MeshNode lifecycle and forwards sync events to the app layer.
///
/// Manages multi-transport sync (LAN, Bluetooth mesh, global relay) through
/// a single unified interface.
public final class NetworkService {

    // MARK: - State

    /// Whether the mesh network is currently active.
    public private(set) var isRunning: Bool = false

    /// The underlying MeshNode (nil when stopped).
    public private(set) var meshNode: MeshNode?

    /// The underlying GhostNode (convenience accessor).
    public var ghostNode: GhostNode? { meshNode?.ghostNode }

    /// Number of artifacts synced in the current session.
    public internal(set) var syncedArtifactCount: Int = 0

    /// Last sync error, if any.
    public internal(set) var lastError: String?

    /// The currently active transport name (Local, Mesh, or Global).
    public var activeTransport: String? { meshNode?.activeTransportName }

    /// Callback invoked when a new artifact arrives via sync.
    public var onArtifactReceived: ((String, String) -> Void)?

    /// Callback invoked when a burn notice is processed.
    public var onBurnProcessed: ((String, String) -> Void)?

    /// Callback invoked when sync completes with a peer.
    public var onSyncCompleted: ((String) -> Void)?

    /// Callback invoked when the active transport changes.
    public var onTransportChanged: ((String) -> Void)?

    /// Callback invoked when a peer connects.
    public var onPeerConnected: ((String, String) -> Void)?

    /// Callback invoked when a peer disconnects.
    public var onPeerDisconnected: ((String) -> Void)?

    // MARK: - Configuration

    /// Optional relay server URL for global sync.
    public var relayURL: URL?

    // MARK: - Dependencies

    private let appState: AppState

    // MARK: - Init

    public init(appState: AppState, relayURL: URL? = nil) {
        self.appState = appState
        self.relayURL = relayURL
    }

    // MARK: - Lifecycle

    /// Start mesh network discovery and sync for the active circle.
    public func start() throws {
        guard let circleID = appState.activeCircleID,
              let circleKey = appState.circleKeys[circleID] else {
            throw VeuAppError.noActiveCircle
        }

        // Debug: print circle key hash for verification
        let keyHash = circleKey.keyData.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("[NetworkService] Starting with circleID=\(circleID.prefix(8))…, keyHash=\(keyHash)…")
        
        let node = MeshNode(
            deviceID: appState.identity.deviceID,
            circleID: circleID,
            circleKey: circleKey.keyData,
            ledger: appState.ledger,
            relayURL: relayURL,
            deviceName: appState.identity.callsign
        )

        node.delegate = self
        try node.start()
        meshNode = node
        isRunning = true
        syncedArtifactCount = 0
        lastError = nil
    }

    /// Stop mesh network.
    public func stop() {
        meshNode?.stop()
        meshNode = nil
        isRunning = false
    }

    /// Restart with the current active circle (e.g., after switching circles).
    public func restart() throws {
        stop()
        try start()
    }

    /// Register an APNs push token for background wake-up.
    public func registerPushToken(_ token: String) {
        meshNode?.registerPushToken(token)
    }
}

// MARK: - MeshNodeDelegate

extension NetworkService: MeshNodeDelegate {
    public func meshNode(_ node: MeshNode, didChangeActiveTransport name: String) {
        onTransportChanged?(name)
    }

    public func meshNode(_ node: MeshNode, didConnectPeer peerID: String, via transport: String) {
        onPeerConnected?(peerID, transport)
    }

    public func meshNode(_ node: MeshNode, didDisconnectPeer peerID: String) {
        onPeerDisconnected?(peerID)
    }

    public func meshNode(_ node: MeshNode, didReceiveArtifact cid: String, circleID: String) {
        syncedArtifactCount += 1
        onArtifactReceived?(cid, circleID)
    }

    public func meshNode(_ node: MeshNode, didProcessBurn cid: String, circleID: String) {
        onBurnProcessed?(cid, circleID)
    }

    public func meshNode(_ node: MeshNode, didCompleteSyncWith peerID: String) {
        onSyncCompleted?(peerID)
    }

    public func meshNode(_ node: MeshNode, didFailWith error: Error) {
        lastError = "\(error)"
    }
}
