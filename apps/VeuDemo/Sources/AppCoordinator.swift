import SwiftUI
import VeuApp
import VeuAuth
import VeuGlaze
import VeuGhost
import MultipeerConnectivity

/// Central coordinator managing app state and all service lifecycles.
final class AppCoordinator: ObservableObject {

    // MARK: - Published state

    @Published var appState: AppState?
    @Published var handshakePhase: HandshakePhase = .idle
    @Published var shortCode: String?
    @Published var auraColorHex: String?
    @Published var timelineEntries: [TimelineEntry] = []
    @Published var networkRunning = false
    @Published var syncedCount = 0
    @Published var networkError: String?
    @Published var handshakeProgress: Float = 0
    @Published var peerCount = 0
    @Published var networkLog: [String] = []

    // Proximity handshake state
    @Published var proximityStatus: String = ""
    @Published var proximityDistance: Float?
    @Published var proximityDirection: SIMD3<Float>?
    @Published var proximityVerified = false
    @Published var discoveredPeerName: String?

    // MARK: - Internal

    private var handshakeVM: HandshakeViewModel?
    private var timelineVM: TimelineViewModel?
    private var networkService: NetworkService?
    private var pulseLogger: PulseLogger?
    private var proximitySession: ProximitySession?

    // MARK: - Bootstrap

    func bootstrap() {
        do {
            let state = try AppState.bootstrap()
            DispatchQueue.main.async {
                self.appState = state
            }
        } catch {
            print("Bootstrap failed: \(error)")
        }
    }

    // MARK: - Proximity Handshake

    func initiateHandshake() {
        guard let state = appState else { return }
        let vm = HandshakeViewModel(appState: state)
        handshakeVM = vm

        do {
            try vm.initiate()
            handshakePhase = .initiating
            handshakeProgress = 0.25
            proximityStatus = "Searching for nearby device…"

            // Get our public key from the Dead Link
            guard let deadLinkURI = vm.deadLinkURI,
                  let link = try? DeadLink.parse(uri: deadLinkURI) else { return }

            let session = ProximitySession()
            session.delegate = self
            session.startAsInitiator(
                deviceName: state.identity.callsign,
                publicKey: link.publicKey.rawRepresentation,
                circleID: vm.circleID
            )
            proximitySession = session
        } catch {
            print("Initiate failed: \(error)")
        }
    }

    func joinHandshake() {
        guard let state = appState else { return }
        handshakePhase = .awaiting
        handshakeProgress = 0.5
        proximityStatus = "Searching for nearby device…"

        let session = ProximitySession()
        session.delegate = self
        // Responder doesn't have a public key yet — generate a temporary keypair
        // The actual handshake will happen when we receive the initiator's payload
        let tempKeypair = EphemeralKeypair.generate()
        session.startAsResponder(
            deviceName: state.identity.callsign,
            publicKey: tempKeypair.publicKey.rawRepresentation
        )
        proximitySession = session

        // Store the keypair so we can use it in the handshake
        _responderKeypair = tempKeypair
    }

    private var _responderKeypair: EphemeralKeypair?

    /// Handle received handshake payload from the proximity peer.
    func handleProximityHandshake(_ payload: ProximityHandshakePayload) {
        guard let state = appState else { return }

        if payload.role == "initiator" {
            // We are the responder — construct a Dead Link URI from the payload and respond
            let vm = HandshakeViewModel(appState: state, circleID: payload.circleID)
            handshakeVM = vm

            // Build a minimal Dead Link URI from the initiator's public key
            // The responder needs to call respond(to:) which parses a URI
            // Instead, we directly use the HandshakeSession for the key exchange
            do {
                let session = HandshakeSession(circleID: payload.circleID)
                // Generate our keypair and perform ECDH with the initiator's public key
                let keypair = _responderKeypair ?? EphemeralKeypair.generate()
                _responderKeypair = nil

                // Use the low-level handshake: set up session manually
                vm.receiveRemotePublicKey(payload.publicKey)
                try vm.respondDirect(
                    remotePublicKey: payload.publicKey,
                    localKeypair: keypair,
                    circleID: payload.circleID
                )
                updateHandshakeState(from: vm)
            } catch {
                print("Respond to proximity handshake failed: \(error)")
                proximityStatus = "Handshake failed: \(error.localizedDescription)"
            }
        } else {
            // We are the initiator — we received the responder's public key
            guard let vm = handshakeVM else { return }
            do {
                try vm.receiveResponse(remotePublicKeyData: payload.publicKey)
                updateHandshakeState(from: vm)
            } catch {
                print("Receive proximity response failed: \(error)")
                proximityStatus = "Handshake failed: \(error.localizedDescription)"
            }
        }
    }

    func confirmHandshake() {
        guard let vm = handshakeVM else { return }
        do {
            try vm.confirm()
            updateHandshakeState(from: vm)
            reloadTimeline()
            // Clean up proximity session
            proximitySession?.stop()
            proximitySession = nil
        } catch {
            print("Confirm failed: \(error)")
        }
    }

    func rejectHandshake() {
        handshakeVM?.reject()
        if let vm = handshakeVM {
            updateHandshakeState(from: vm)
        }
        proximitySession?.stop()
        proximitySession = nil
    }

    func resetHandshake() {
        handshakeVM?.reset()
        handshakePhase = .idle
        shortCode = nil
        auraColorHex = nil
        handshakeProgress = 0
        proximityStatus = ""
        proximityDistance = nil
        proximityDirection = nil
        proximityVerified = false
        discoveredPeerName = nil
        _responderKeypair = nil
        proximitySession?.stop()
        proximitySession = nil
    }

    private func updateHandshakeState(from vm: HandshakeViewModel) {
        handshakePhase = vm.phase
        shortCode = vm.shortCode
        auraColorHex = vm.auraColorHex

        switch vm.phase {
        case .idle: handshakeProgress = 0
        case .initiating: handshakeProgress = 0.25
        case .awaiting: handshakeProgress = 0.5
        case .verifying:
            handshakeProgress = 0.75
            proximityStatus = "Verify short code"
        case .confirmed: handshakeProgress = 1.0
        case .deadLink, .ghost: handshakeProgress = 0
        }
    }

    // MARK: - Timeline

    func reloadTimeline() {
        guard let state = appState else { return }
        let vm = TimelineViewModel(appState: state)
        timelineVM = vm
        do {
            try vm.reload()
            timelineEntries = vm.entries
        } catch {
            print("Reload failed: \(error)")
        }
    }

    func sealArtifact(data: Data, burnAfter: Int?) {
        guard let state = appState else { return }
        let vm = timelineVM ?? TimelineViewModel(appState: state)
        timelineVM = vm
        do {
            let result = try vm.compose(data: data, burnAfter: burnAfter)
            timelineEntries = vm.entries
            // Notify the ghost network so it can sync the new artifact to peers
            if let node = networkService?.ghostNode, let circleID = state.activeCircleID {
                node.syncEngine.recordLocalArtifact(circleID: circleID)
                node.resyncAllPeers()
            }
        } catch {
            print("Seal failed: \(error)")
        }
    }

    // MARK: - Network

    func startNetwork() {
        guard let state = appState else { return }
        let service = NetworkService(appState: state)
        networkService = service

        service.onArtifactReceived = { [weak self] cid, circleID in
            DispatchQueue.main.async {
                self?.syncedCount += 1
                self?.networkLog.append("📥 Received artifact \(String(cid.prefix(8)))…")
                self?.reloadTimeline()
            }
        }

        service.onSyncCompleted = { [weak self] peerID in
            DispatchQueue.main.async {
                self?.networkLog.append("✅ Sync complete with \(peerID)")
                self?.reloadTimeline()
            }
        }

        do {
            try service.start()
            networkRunning = true
            networkError = nil
            networkLog.append("🟢 Network started (circle: \(state.activeCircleID?.prefix(8) ?? "?")…)")

            // Log discovery events
            if let node = service.ghostNode {
                let originalDelegate = node.pulse.delegate
                let logger = PulseLogger(
                    coordinator: self,
                    inner: originalDelegate
                )
                self.pulseLogger = logger
                node.pulse.delegate = logger
            }
        } catch {
            networkError = "\(error)"
            networkLog.append("🔴 Start failed: \(error)")
        }
    }

    func stopNetwork() {
        networkService?.stop()
        networkService = nil
        pulseLogger = nil
        networkRunning = false
    }
}

// MARK: - ProximitySessionDelegate

extension AppCoordinator: ProximitySessionDelegate {

    func proximitySession(_ session: ProximitySession, didDiscoverPeer peerID: MCPeerID) {
        discoveredPeerName = peerID.displayName
        proximityStatus = "Found \(peerID.displayName) nearby"
    }

    func proximitySession(_ session: ProximitySession, didReceiveHandshake payload: ProximityHandshakePayload) {
        proximityStatus = "Key exchange in progress…"
        handleProximityHandshake(payload)
    }

    func proximitySession(_ session: ProximitySession, didVerifyProximity distance: Float, direction: SIMD3<Float>?) {
        proximityDistance = distance
        proximityDirection = direction
        proximityVerified = true
        proximityStatus = String(format: "✅ Verified: %.0fcm away", distance * 100)
    }

    func proximitySession(_ session: ProximitySession, proximityCheckFailed distance: Float) {
        proximityDistance = distance
        proximityStatus = String(format: "⚠️ Move closer (%.1fm away, need <%.1fm)", distance, ProximitySession.proximityThreshold)
    }

    func proximitySession(_ session: ProximitySession, didFailWith error: Error) {
        proximityStatus = "Error: \(error.localizedDescription)"
    }

    func proximitySessionDidDisconnect(_ session: ProximitySession) {
        proximityStatus = "Peer disconnected"
    }
}

// MARK: - Discovery Logger

import Network

final class PulseLogger: LocalPulseDelegate {
    weak var coordinator: AppCoordinator?
    weak var inner: LocalPulseDelegate?

    init(coordinator: AppCoordinator, inner: LocalPulseDelegate?) {
        self.coordinator = coordinator
        self.inner = inner
    }

    func localPulse(_ pulse: LocalPulse, didDiscover endpoint: NWEndpoint, topicHash: String) {
        DispatchQueue.main.async {
            self.coordinator?.peerCount += 1
            self.coordinator?.networkLog.append("🔍 Discovered peer: \(endpoint)")
        }
        inner?.localPulse(pulse, didDiscover: endpoint, topicHash: topicHash)
    }

    func localPulse(_ pulse: LocalPulse, didLose endpoint: NWEndpoint) {
        DispatchQueue.main.async {
            self.coordinator?.peerCount = max(0, (self.coordinator?.peerCount ?? 1) - 1)
            self.coordinator?.networkLog.append("👻 Lost peer: \(endpoint)")
        }
        inner?.localPulse(pulse, didLose: endpoint)
    }

    func localPulse(_ pulse: LocalPulse, didAcceptConnection connection: NWConnection) {
        DispatchQueue.main.async {
            self.coordinator?.networkLog.append("🤝 Accepted connection: \(connection.endpoint)")
        }
        inner?.localPulse(pulse, didAcceptConnection: connection)
    }
}
