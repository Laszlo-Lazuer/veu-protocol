// MeshTransportProtocol.swift — Veu Protocol: Mesh Transport Interface
//
// Higher-level transport protocol for the mesh layer.  Each transport
// implementation (Local, Bluetooth mesh, Global relay) conforms to this
// protocol to participate in multi-transport sync.

import Foundation
import VeuGhost

/// The current state of a mesh transport.
public enum MeshTransportState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

public struct RelayDeliveryUpdate: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case accepted
        case duplicate
        case rejected
    }

    public let cid: String
    public let status: Status
    public let detail: String?

    public init(cid: String, status: Status, detail: String? = nil) {
        self.cid = cid
        self.status = status
        self.detail = detail
    }
}

/// Delegate for mesh transport lifecycle and data events.
public protocol MeshTransportDelegate: AnyObject {
    /// Transport state changed.
    func transport(_ transport: any MeshTransportProtocol, didChangeState state: MeshTransportState)

    /// A new peer connection was established (inbound or outbound).
    func transport(_ transport: any MeshTransportProtocol, didConnectPeer connection: any TransportConnection)

    /// A peer connection was lost.
    func transport(_ transport: any MeshTransportProtocol, didDisconnectPeer peerID: String)

    /// The relay reported whether a locally-sent artifact was accepted or rejected.
    func transport(_ transport: any MeshTransportProtocol, didUpdateRelayDelivery update: RelayDeliveryUpdate)
}

public extension MeshTransportDelegate {
    func transport(_ transport: any MeshTransportProtocol, didUpdateRelayDelivery update: RelayDeliveryUpdate) {}
}

/// A mesh transport that can discover peers and establish connections.
///
/// Concrete implementations:
/// - `LocalTransport` (LAN/mDNS wrapper around LocalPulse)
/// - `MeshTransport` (Bluetooth LE + AWDL multi-hop via MultipeerConnectivity)
/// - `GlobalTransport` (WebSocket relay)
public protocol MeshTransportProtocol: AnyObject {
    /// Human-readable transport name (e.g., "Local", "Mesh", "Global").
    var name: String { get }

    /// Current transport state.
    var state: MeshTransportState { get }

    /// Whether this transport is currently connected and able to sync.
    var isAvailable: Bool { get }

    /// Delegate for transport events.
    var delegate: (any MeshTransportDelegate)? { get set }

    /// Start the transport (begin discovery and/or connect).
    func start() throws

    /// Stop the transport (disconnect and stop discovery).
    func stop()
}
