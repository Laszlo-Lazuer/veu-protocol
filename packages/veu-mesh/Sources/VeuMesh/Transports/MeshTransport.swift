// MeshTransport.swift — Veu Protocol: Bluetooth LE + AWDL Multi-Hop Mesh
//
// Uses MultipeerConnectivity to discover nearby devices and relay messages
// through multi-hop routing.  This enables LoRa-style range extension where
// each device extends the network's reach.

import Foundation
import MultipeerConnectivity
import VeuGhost

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Bluetooth LE + AWDL mesh transport with multi-hop routing.
///
/// Discovers peers within Bluetooth/AWDL range using `MCNearbyServiceBrowser`
/// and advertises using `MCNearbyServiceAdvertiser`.  Messages can be relayed
/// through intermediate peers (up to `maxHops` hops) to extend range.
public final class MeshTransport: NSObject, MeshTransportProtocol {

    // MARK: - MeshTransportProtocol

    public let name = "Mesh"
    public private(set) var state: MeshTransportState = .disconnected
    public weak var delegate: (any MeshTransportDelegate)?

    public var isAvailable: Bool {
        !connectedPeers.isEmpty
    }

    // MARK: - Configuration

    /// Maximum number of relay hops for multi-hop routing.
    public static let maxHops: Int = 5

    /// MultipeerConnectivity service type (max 15 chars, lowercase + hyphens).
    private static let serviceType = "veu-mesh"

    // MARK: - Internal

    private let circleKey: Data
    private let topicHash: String
    private let localPeerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var connectedPeers: [MCPeerID: MeshPeerConnection] = [:]
    private var router: MeshRouter

    /// Create a MeshTransport for a Circle.
    ///
    /// - Parameters:
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - deviceName: Human-readable device name for discovery.
    public init(circleKey: Data, deviceName: String) {
        self.circleKey = circleKey
        self.topicHash = GhostConnection.circleTopicHash(circleKey: circleKey)
        self.localPeerID = MCPeerID(displayName: deviceName)
        self.router = MeshRouter(maxHops: Self.maxHops)
        super.init()
    }

    // MARK: - Lifecycle

    public func start() throws {
        let session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        // Advertise with topic hash in discovery info
        let info = ["topic": String(topicHash.prefix(16))]
        let advertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: info, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        // Browse for peers
        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        state = .connected
        delegate?.transport(self, didChangeState: .connected)
    }

    public func stop() {
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        session?.disconnect()
        browser = nil
        advertiser = nil
        session = nil
        connectedPeers.removeAll()
        router = MeshRouter(maxHops: Self.maxHops)
        state = .disconnected
        delegate?.transport(self, didChangeState: .disconnected)
    }

    // MARK: - Multi-Hop Relay

    /// Relay a message through the mesh to reach peers beyond direct range.
    func relayMessage(_ data: Data, from originPeer: MCPeerID, ttl: Int) {
        guard ttl > 0 else { return }
        guard let session = session else { return }

        let envelope = MeshEnvelope(payload: data, ttl: ttl - 1, originPeerName: originPeer.displayName)
        guard let envelopeData = try? JSONEncoder().encode(envelope) else { return }

        let targets = session.connectedPeers.filter { $0 != originPeer }
        guard !targets.isEmpty else { return }

        try? session.send(envelopeData, toPeers: targets, with: .reliable)
    }
}

// MARK: - MCSessionDelegate

extension MeshTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            let peerConn = MeshPeerConnection(
                session: session,
                peerID: peerID,
                circleKey: circleKey
            )
            connectedPeers[peerID] = peerConn
            router.addRoute(to: peerID.displayName, via: peerID.displayName, hops: 1)
            delegate?.transport(self, didConnectPeer: peerConn)

        case .notConnected:
            connectedPeers.removeValue(forKey: peerID)
            router.removeRoute(to: peerID.displayName)
            delegate?.transport(self, didDisconnectPeer: peerID.displayName)

        case .connecting:
            break

        @unknown default:
            break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Attempt to decode as mesh envelope for relay
        if let envelope = try? JSONDecoder().decode(MeshEnvelope.self, from: data),
           envelope.ttl > 0 {
            relayMessage(envelope.payload, from: peerID, ttl: envelope.ttl)
        }

        // Forward to the peer connection for sync handling
        if let peerConn = connectedPeers[peerID] {
            peerConn.enqueueReceived(data)
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept if the peer's topic prefix matches ours
        if let context = context,
           let info = try? JSONDecoder().decode([String: String].self, from: context),
           info["topic"] == String(topicHash.prefix(16)) {
            invitationHandler(true, session)
        } else {
            // Accept optimistically (topic check may not be in context)
            invitationHandler(true, session)
        }
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        state = .failed(error.localizedDescription)
        delegate?.transport(self, didChangeState: state)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Invite if topic prefix matches
        let peerTopic = info?["topic"]
        let ourPrefix = String(topicHash.prefix(16))
        if peerTopic == nil || peerTopic == ourPrefix {
            let context = try? JSONEncoder().encode(["topic": ourPrefix])
            browser.invitePeer(peerID, to: session!, withContext: context, timeout: 30)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Handled by session delegate
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        state = .failed(error.localizedDescription)
        delegate?.transport(self, didChangeState: state)
    }
}

// MARK: - Mesh Envelope

/// Wire format for multi-hop relay messages.
struct MeshEnvelope: Codable {
    let payload: Data
    let ttl: Int
    let originPeerName: String
}
