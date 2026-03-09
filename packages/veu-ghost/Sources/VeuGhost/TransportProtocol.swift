// TransportProtocol.swift — Veu Protocol: Pluggable Transport Interface
//
// Defines the transport abstraction for the Ghost Network.  Any transport
// (TCP, Bluetooth LE, WebSocket relay) conforms to this protocol to enable
// encrypted message exchange over that medium.

import Foundation

/// A transport connection capable of sending and receiving `GhostMessage`s.
///
/// Concrete implementations:
/// - `GhostConnection` (NWConnection/TCP — LAN)
/// - `MeshPeerConnection` (MultipeerConnectivity — Bluetooth/AWDL)
/// - `RelayConnection` (URLSessionWebSocketTask — global relay)
public protocol TransportConnection: AnyObject {
    /// A human-readable description of the remote endpoint (for logging).
    var endpointDescription: String { get }

    /// Encrypt and send a `GhostMessage` over this transport.
    func send(_ message: GhostMessage, completion: @escaping (Result<Void, VeuGhostError>) -> Void)

    /// Receive and decrypt a single `GhostMessage` from this transport.
    func receive(completion: @escaping (Result<GhostMessage, VeuGhostError>) -> Void)

    /// Tear down the connection.
    func cancel()
}
