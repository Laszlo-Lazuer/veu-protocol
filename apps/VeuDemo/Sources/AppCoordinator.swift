import SwiftUI
import VeuApp
import VeuAuth
import VeuGlaze
import VeuGhost

/// Central coordinator managing app state and all service lifecycles.
final class AppCoordinator: ObservableObject {

    // MARK: - Published state

    @Published var appState: AppState?
    @Published var handshakePhase: HandshakePhase = .idle
    @Published var deadLinkURI: String?
    @Published var shortCode: String?
    @Published var auraColorHex: String?
    @Published var timelineEntries: [TimelineEntry] = []
    @Published var networkRunning = false
    @Published var syncedCount = 0
    @Published var networkError: String?
    @Published var handshakeProgress: Float = 0
    @Published var responsePayload: String?
    @Published var peerCount = 0
    @Published var networkLog: [String] = []

    // MARK: - Internal

    private var handshakeVM: HandshakeViewModel?
    private var timelineVM: TimelineViewModel?
    private var networkService: NetworkService?
    private var pulseLogger: PulseLogger?

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

    // MARK: - Handshake

    func initiateHandshake() {
        guard let state = appState else { return }
        let vm = HandshakeViewModel(appState: state)
        handshakeVM = vm
        do {
            try vm.initiate()
            updateHandshakeState(from: vm)
            // Append circleID to the Dead Link URI so the responder derives the same key
            if let base = deadLinkURI {
                deadLinkURI = base + "&cid=\(vm.circleID)"
            }
        } catch {
            print("Initiate failed: \(error)")
        }
    }

    func respondToHandshake(uri: String) {
        guard let state = appState else { return }
        // Extract the initiator's circleID from the URI so both sides use the same one
        var circleID: String? = nil
        if let components = URLComponents(string: uri),
           let cid = components.queryItems?.first(where: { $0.name == "cid" })?.value {
            circleID = cid
        }
        let vm = HandshakeViewModel(appState: state, circleID: circleID)
        handshakeVM = vm
        do {
            let pubKeyData = try vm.respond(to: uri)
            updateHandshakeState(from: vm)
            // Encode responder's public key as a URI for the initiator to scan
            responsePayload = "veu://response?pk=\(pubKeyData.base64URLEncoded())"
        } catch {
            print("Respond failed: \(error)")
        }
    }

    func receiveResponse(uri: String) {
        guard let vm = handshakeVM else { return }
        guard let components = URLComponents(string: uri),
              components.scheme == "veu",
              components.host == "response",
              let pkStr = components.queryItems?.first(where: { $0.name == "pk" })?.value,
              let pkData = Data(base64URLEncoded: pkStr) else {
            print("Invalid response URI")
            return
        }
        do {
            try vm.receiveResponse(remotePublicKeyData: pkData)
            updateHandshakeState(from: vm)
        } catch {
            print("Receive response failed: \(error)")
        }
    }

    func confirmHandshake() {
        guard let vm = handshakeVM else { return }
        do {
            try vm.confirm()
            updateHandshakeState(from: vm)
            reloadTimeline()
        } catch {
            print("Confirm failed: \(error)")
        }
    }

    func rejectHandshake() {
        handshakeVM?.reject()
        if let vm = handshakeVM {
            updateHandshakeState(from: vm)
        }
    }

    func resetHandshake() {
        handshakeVM?.reset()
        handshakePhase = .idle
        deadLinkURI = nil
        shortCode = nil
        auraColorHex = nil
        handshakeProgress = 0
        responsePayload = nil
    }

    private func updateHandshakeState(from vm: HandshakeViewModel) {
        handshakePhase = vm.phase
        deadLinkURI = vm.deadLinkURI
        shortCode = vm.shortCode
        auraColorHex = vm.auraColorHex

        switch vm.phase {
        case .idle: handshakeProgress = 0
        case .initiating: handshakeProgress = 0.25
        case .awaiting: handshakeProgress = 0.5
        case .verifying: handshakeProgress = 0.75
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
