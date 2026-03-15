// NetworkTransitionManager.swift — Veu Protocol: Mid-call network handoff
//
// Monitors network path changes (WiFi ↔ cellular) during active voice calls.
// Automatically switches between direct UDP (local) and relay (remote) audio
// transport without dropping the call.

#if os(iOS)
import Foundation
import Network

/// Monitors network transitions and notifies the voice call manager to switch
/// audio transport when the network path changes mid-call.
public final class NetworkTransitionManager {

    /// Current network path type.
    public enum PathType: Equatable {
        case wifi
        case cellular
        case wired
        case unknown
        case noNetwork
    }

    /// Called when network path changes. Passes (old, new) path types.
    public var onPathChanged: ((_ old: PathType, _ new: PathType) -> Void)?

    /// Called when the network is lost entirely.
    public var onNetworkLost: (() -> Void)?

    /// Called when the network is restored after a loss.
    public var onNetworkRestored: ((_ pathType: PathType) -> Void)?

    public private(set) var currentPath: PathType = .unknown
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "veu.network-transition", qos: .userInteractive)

    public init() {
        self.monitor = NWPathMonitor()
    }

    /// Start monitoring network path changes.
    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let newType = Self.pathType(from: path)
            let oldType = self.currentPath

            guard newType != oldType else { return }
            self.currentPath = newType

            DispatchQueue.main.async {
                if newType == .noNetwork {
                    print("[NetworkTransition] ❌ Network lost (was: \(oldType))")
                    self.onNetworkLost?()
                } else if oldType == .noNetwork {
                    print("[NetworkTransition] ✅ Network restored: \(newType)")
                    self.onNetworkRestored?(newType)
                } else {
                    print("[NetworkTransition] 🔄 Network changed: \(oldType) → \(newType)")
                    self.onPathChanged?(oldType, newType)
                }
            }
        }
        monitor.start(queue: queue)
    }

    /// Stop monitoring.
    public func stop() {
        monitor.cancel()
    }

    /// Whether the current path supports direct peer connections (same LAN).
    public var supportsDirectPeer: Bool {
        currentPath == .wifi || currentPath == .wired
    }

    private static func pathType(from path: NWPath) -> PathType {
        guard path.status == .satisfied else { return .noNetwork }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .unknown
    }
}
#endif
