// LocalTransport.swift — Veu Protocol: LAN/mDNS Transport Wrapper
//
// Wraps the existing LocalPulse (mDNS/Bonjour) discovery and GhostConnection
// into the MeshTransportProtocol interface for the mesh layer.

import Foundation
import Network
import VeuGhost

/// LAN transport using mDNS/Bonjour peer discovery (wraps `LocalPulse`).
///
/// This is the highest-priority transport — used when devices are on the
/// same Wi-Fi network or within AWDL (Wi-Fi Direct) range.
public final class LocalTransport: MeshTransportProtocol {

    // MARK: - MeshTransportProtocol

    public let name = "Local"
    public private(set) var state: MeshTransportState = .disconnected
    public weak var delegate: (any MeshTransportDelegate)?

    public var isAvailable: Bool {
        pulse.isActive
    }

    // MARK: - Internal

    private let pulse: LocalPulse
    private let circleKey: Data
    private let queue: DispatchQueue

    /// Create a LocalTransport for a Circle.
    ///
    /// - Parameters:
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - queue: Dispatch queue for events.
    public init(circleKey: Data, queue: DispatchQueue = .main) {
        self.circleKey = circleKey
        self.queue = queue
        self.pulse = LocalPulse(circleKey: circleKey, queue: queue)
    }

    /// The underlying LocalPulse (exposed for logging/debugging).
    public var localPulse: LocalPulse { pulse }

    // MARK: - Lifecycle

    public func start() throws {
        pulse.delegate = self
        try pulse.start()
        state = .connected
        delegate?.transport(self, didChangeState: .connected)
    }

    public func stop() {
        pulse.stop()
        state = .disconnected
        delegate?.transport(self, didChangeState: .disconnected)
    }
}

// MARK: - LocalPulseDelegate

extension LocalTransport: LocalPulseDelegate {
    public func localPulse(_ pulse: LocalPulse, didDiscover endpoint: NWEndpoint, topicHash: String) {
        let conn = GhostConnection(endpoint: endpoint, circleKey: circleKey)
        conn.start(queue: queue)
        delegate?.transport(self, didConnectPeer: conn)
    }

    public func localPulse(_ pulse: LocalPulse, didLose endpoint: NWEndpoint) {
        delegate?.transport(self, didDisconnectPeer: "\(endpoint)")
    }

    public func localPulse(_ pulse: LocalPulse, didAcceptConnection connection: NWConnection) {
        let conn = GhostConnection(connection: connection, circleKey: circleKey)
        delegate?.transport(self, didConnectPeer: conn)
    }
}
