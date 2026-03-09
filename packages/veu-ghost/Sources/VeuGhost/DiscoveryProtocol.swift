// DiscoveryProtocol.swift — Veu Protocol: Pluggable Discovery Interface
//
// Defines the discovery abstraction for the Ghost Network.  Any discovery
// mechanism (mDNS, Bluetooth scan, relay subscription) conforms to this
// protocol to announce presence and find peers.

import Foundation

/// Delegate for peer discovery events from any discovery mechanism.
public protocol DiscoveryDelegate: AnyObject {
    /// A new peer was discovered.  The `peerID` is transport-opaque.
    func discovery(_ discovery: any DiscoveryService, didDiscoverPeer peerID: String)

    /// A previously discovered peer is no longer available.
    func discovery(_ discovery: any DiscoveryService, didLosePeer peerID: String)

    /// An inbound connection was accepted from a peer.
    func discovery(_ discovery: any DiscoveryService, didAcceptConnection connection: any TransportConnection)
}

/// A discovery service that advertises and discovers Ghost Network peers.
///
/// Concrete implementations:
/// - `LocalPulse` (mDNS/Bonjour — LAN)
/// - `MeshDiscovery` (MultipeerConnectivity — Bluetooth/AWDL)
/// - `RelayDiscovery` (WebSocket relay subscription — global)
public protocol DiscoveryService: AnyObject {
    /// Whether the service is currently active.
    var isActive: Bool { get }

    /// Delegate receiving discovery events.
    var discoveryDelegate: (any DiscoveryDelegate)? { get set }

    /// Start advertising and discovering peers.
    func startDiscovery() throws

    /// Stop advertising and discovering.
    func stopDiscovery()
}
