// ProximitySession.swift — Veu Protocol: MultipeerConnectivity + UWB Handshake Transport
//
// Replaces QR code scanning with proximity-based key exchange.
// Uses MultipeerConnectivity for peer discovery and data transfer,
// and Nearby Interaction (UWB) for cryptographic distance verification.

import Foundation
import MultipeerConnectivity
import NearbyInteraction

/// Delegate protocol for ProximitySession events.
protocol ProximitySessionDelegate: AnyObject {
    /// Called when a nearby peer is discovered and ready for handshake.
    func proximitySession(_ session: ProximitySession, didDiscoverPeer peerID: MCPeerID)
    /// Called when the peer's public key and circleID are received.
    func proximitySession(_ session: ProximitySession, didReceiveHandshake payload: ProximityHandshakePayload)
    /// Called when UWB proximity is verified with distance in meters.
    func proximitySession(_ session: ProximitySession, didVerifyProximity distance: Float, direction: SIMD3<Float>?)
    /// Called when proximity check fails (peer too far away).
    func proximitySession(_ session: ProximitySession, proximityCheckFailed distance: Float)
    /// Called on error.
    func proximitySession(_ session: ProximitySession, didFailWith error: Error)
    /// Called when the peer disconnects.
    func proximitySessionDidDisconnect(_ session: ProximitySession)
}

/// Payload exchanged during the proximity handshake.
struct ProximityHandshakePayload: Codable {
    let publicKey: Data       // 32-byte X25519 public key
    let circleID: String      // UUID string
    let role: String          // "initiator" or "responder"
}

/// Manages MultipeerConnectivity + Nearby Interaction for proximity-based handshakes.
final class ProximitySession: NSObject {

    // MARK: - Configuration

    static let serviceType = "veu-handshake"
    /// Maximum distance in meters for UWB proximity verification.
    static let proximityThreshold: Float = 1.0

    // MARK: - State

    enum Role { case initiator, responder }
    enum State {
        case idle
        case advertising
        case browsing
        case connecting
        case exchangingKeys
        case verifyingProximity
        case verified
        case failed(Error)
    }

    private(set) var state: State = .idle
    private(set) var role: Role?
    private(set) var peerDistance: Float?
    private(set) var peerDirection: SIMD3<Float>?
    private(set) var isProximityVerified = false

    weak var delegate: ProximitySessionDelegate?

    // MARK: - MultipeerConnectivity

    private var localPeerID: MCPeerID!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var mcSession: MCSession?
    private var connectedPeer: MCPeerID?

    // MARK: - Nearby Interaction

    private var niSession: NISession?
    private var myNIToken: NIDiscoveryToken?

    // MARK: - Handshake Data

    private var localPublicKey: Data?
    private var localCircleID: String?

    // MARK: - Lifecycle

    /// Start as initiator — advertise availability and wait for a peer to connect.
    func startAsInitiator(deviceName: String, publicKey: Data, circleID: String) {
        role = .initiator
        localPublicKey = publicKey
        localCircleID = circleID

        setupMCSession(deviceName: deviceName)
        setupNISession()

        advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: ["role": "initiator"],
            serviceType: ProximitySession.serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        // Also browse so we can find responders quickly
        browser = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: ProximitySession.serviceType
        )
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        state = .advertising
    }

    /// Start as responder — browse for an initiator and connect.
    func startAsResponder(deviceName: String, publicKey: Data, circleID: String? = nil) {
        role = .responder
        localPublicKey = publicKey
        localCircleID = circleID

        setupMCSession(deviceName: deviceName)
        setupNISession()

        // Advertise so initiator can find us
        advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: ["role": "responder"],
            serviceType: ProximitySession.serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        // Browse for initiators
        browser = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: ProximitySession.serviceType
        )
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        state = .browsing
    }

    /// Stop everything and clean up.
    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        mcSession?.disconnect()
        niSession?.invalidate()

        advertiser = nil
        browser = nil
        mcSession = nil
        niSession = nil
        connectedPeer = nil
        state = .idle
        isProximityVerified = false
        peerDistance = nil
        peerDirection = nil
    }

    // MARK: - Private Setup

    private func setupMCSession(deviceName: String) {
        localPeerID = MCPeerID(displayName: deviceName)
        mcSession = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        mcSession?.delegate = self
    }

    private func setupNISession() {
        guard NISession.isSupported else {
            print("[Proximity] UWB not supported on this device")
            return
        }
        niSession = NISession()
        niSession?.delegate = self
        myNIToken = niSession?.discoveryToken
    }

    // MARK: - Data Exchange

    /// Send the handshake payload (public key + circleID) to the connected peer.
    private func sendHandshakePayload() {
        guard let session = mcSession,
              let peer = connectedPeer,
              let pubKey = localPublicKey else { return }

        let payload = ProximityHandshakePayload(
            publicKey: pubKey,
            circleID: localCircleID ?? "",
            role: role == .initiator ? "initiator" : "responder"
        )

        do {
            let data = try JSONEncoder().encode(payload)
            try session.send(data, toPeers: [peer], with: .reliable)
            print("[Proximity] Sent handshake payload (\(data.count) bytes)")
            state = .exchangingKeys
        } catch {
            print("[Proximity] Failed to send payload: \(error)")
            delegate?.proximitySession(self, didFailWith: error)
        }
    }

    /// Exchange NI discovery tokens for UWB ranging.
    private func sendNIDiscoveryToken() {
        guard let session = mcSession,
              let peer = connectedPeer,
              let token = myNIToken else {
            // UWB not available — skip proximity verification
            print("[Proximity] UWB token unavailable, skipping proximity check")
            isProximityVerified = true
            state = .verified
            return
        }

        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: true
            )
            // Tag with a prefix so we can distinguish from handshake payloads
            var tagged = Data([0x4E, 0x49]) // "NI" prefix
            tagged.append(data)
            try session.send(tagged, toPeers: [peer], with: .reliable)
            print("[Proximity] Sent NI discovery token")
        } catch {
            print("[Proximity] Failed to send NI token: \(error)")
        }
    }

    /// Process received NI discovery token and start UWB ranging.
    private func handleNIDiscoveryToken(_ data: Data) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NIDiscoveryToken.self,
            from: data
        ) else {
            print("[Proximity] Failed to decode NI discovery token")
            return
        }

        let config = NINearbyPeerConfiguration(peerToken: token)
        niSession?.run(config)
        state = .verifyingProximity
        print("[Proximity] Started UWB ranging")
    }
}

// MARK: - MCSessionDelegate

extension ProximitySession: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch state {
            case .connected:
                print("[Proximity] Connected to \(peerID.displayName)")
                self.connectedPeer = peerID
                self.state = .connecting
                // Stop discovery once connected
                self.advertiser?.stopAdvertisingPeer()
                self.browser?.stopBrowsingForPeers()
                // Exchange handshake data
                self.sendHandshakePayload()
                // Exchange NI tokens for UWB
                self.sendNIDiscoveryToken()

            case .notConnected:
                print("[Proximity] Disconnected from \(peerID.displayName)")
                if self.connectedPeer == peerID {
                    self.connectedPeer = nil
                    self.delegate?.proximitySessionDidDisconnect(self)
                }

            case .connecting:
                print("[Proximity] Connecting to \(peerID.displayName)…")

            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Check if this is an NI discovery token (tagged with "NI" prefix)
            if data.count > 2 && data[0] == 0x4E && data[1] == 0x49 {
                let tokenData = data.subdata(in: 2..<data.count)
                self.handleNIDiscoveryToken(tokenData)
                return
            }

            // Otherwise it's a handshake payload
            guard let payload = try? JSONDecoder().decode(ProximityHandshakePayload.self, from: data) else {
                print("[Proximity] Received unrecognized data (\(data.count) bytes)")
                return
            }

            print("[Proximity] Received handshake from \(payload.role) (key: \(payload.publicKey.count) bytes, circle: \(String(payload.circleID.prefix(8)))…)")
            self.delegate?.proximitySession(self, didReceiveHandshake: payload)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension ProximitySession: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("[Proximity] Received invitation from \(peerID.displayName)")
        // Accept all invitations — the short code verification is the trust gate
        invitationHandler(true, mcSession)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[Proximity] Advertising failed: \(error)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.proximitySession(self, didFailWith: error)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension ProximitySession: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Don't connect to self
        guard peerID != localPeerID else { return }

        let peerRole = info?["role"] ?? "unknown"
        print("[Proximity] Found peer: \(peerID.displayName) (role: \(peerRole))")

        // Initiators invite responders, responders invite initiators
        let shouldInvite: Bool
        switch role {
        case .initiator:
            shouldInvite = peerRole == "responder"
        case .responder:
            shouldInvite = peerRole == "initiator"
        case .none:
            shouldInvite = false
        }

        if shouldInvite, let session = mcSession {
            print("[Proximity] Inviting \(peerID.displayName)")
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.proximitySession(self, didDiscoverPeer: peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("[Proximity] Lost peer: \(peerID.displayName)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[Proximity] Browse failed: \(error)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.proximitySession(self, didFailWith: error)
        }
    }
}

// MARK: - NISessionDelegate (UWB Proximity Verification)

extension ProximitySession: NISessionDelegate {

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peer = nearbyObjects.first else { return }

        let distance = peer.distance ?? -1
        let direction = peer.direction

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.peerDistance = distance
            if let dir = direction {
                self.peerDirection = dir
            }

            if distance >= 0 && distance <= ProximitySession.proximityThreshold {
                if !self.isProximityVerified {
                    self.isProximityVerified = true
                    self.state = .verified
                    print("[Proximity] ✅ UWB verified: \(String(format: "%.2f", distance))m")
                    self.delegate?.proximitySession(self, didVerifyProximity: distance, direction: direction)
                }
            } else if distance > ProximitySession.proximityThreshold {
                print("[Proximity] ⚠️ Peer too far: \(String(format: "%.2f", distance))m (max: \(ProximitySession.proximityThreshold)m)")
                self.delegate?.proximitySession(self, proximityCheckFailed: distance)
            }
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        print("[Proximity] NI session invalidated: \(error)")
    }

    func sessionWasSuspended(_ session: NISession) {
        print("[Proximity] NI session suspended")
    }

    func sessionSuspensionEnded(_ session: NISession) {
        print("[Proximity] NI session resumed")
        // Re-run the session if we have a config
        if let token = myNIToken {
            let config = NINearbyPeerConfiguration(peerToken: token)
            session.run(config)
        }
    }
}
