import Foundation
import VeuAuth
import VeuCrypto
import VeuGhost
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Wraps GhostNode lifecycle and forwards sync events to the app layer.
public final class NetworkService {

    // MARK: - State

    /// Whether the Ghost Network is currently active.
    public private(set) var isRunning: Bool = false

    /// The underlying GhostNode (nil when stopped).
    public private(set) var ghostNode: GhostNode?

    /// Number of artifacts synced in the current session.
    public internal(set) var syncedArtifactCount: Int = 0

    /// Last sync error, if any.
    public internal(set) var lastError: String?

    /// Callback invoked when a new artifact arrives via sync.
    public var onArtifactReceived: ((String, String) -> Void)?

    /// Callback invoked when a burn notice is processed.
    public var onBurnProcessed: ((String, String) -> Void)?

    /// Callback invoked when sync completes with a peer.
    public var onSyncCompleted: ((String) -> Void)?

    // MARK: - Dependencies

    private let appState: AppState

    // MARK: - Init

    public init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Lifecycle

    /// Start Ghost Network discovery and sync for the active circle.
    public func start() throws {
        guard let circleID = appState.activeCircleID,
              let circleKey = appState.circleKeys[circleID] else {
            throw VeuAppError.noActiveCircle
        }

        let node = GhostNode(
            deviceID: appState.identity.deviceID,
            circleID: circleID,
            circleKey: circleKey.keyData,
            ledger: appState.ledger
        )

        let delegate = SyncDelegate(service: self)
        node.syncDelegate = delegate
        self._syncDelegate = delegate

        try node.start()
        ghostNode = node
        isRunning = true
        syncedArtifactCount = 0
        lastError = nil
    }

    /// Stop Ghost Network.
    public func stop() {
        ghostNode?.stop()
        ghostNode = nil
        isRunning = false
        _syncDelegate = nil
    }

    /// Restart with the current active circle (e.g., after switching circles).
    public func restart() throws {
        stop()
        try start()
    }

    // MARK: - Sync delegate storage (prevent dealloc)
    private var _syncDelegate: SyncDelegate?
}

// MARK: - SyncEngineDelegate bridge

private final class SyncDelegate: SyncEngineDelegate {
    weak var service: NetworkService?

    init(service: NetworkService) {
        self.service = service
    }

    func syncEngine(_ engine: SyncEngine, didReceiveArtifact cid: String, circleID: String) {
        service?.syncedArtifactCount += 1
        service?.onArtifactReceived?(cid, circleID)
    }

    func syncEngine(_ engine: SyncEngine, didProcessBurn cid: String, circleID: String) {
        service?.onBurnProcessed?(cid, circleID)
    }

    func syncEngine(_ engine: SyncEngine, didCompleteSyncWith peerDeviceID: String) {
        service?.onSyncCompleted?(peerDeviceID)
    }

    func syncEngine(_ engine: SyncEngine, didFailWith error: VeuGhostError) {
        service?.lastError = "\(error)"
    }
}
