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

    // MARK: - Internal

    private var handshakeVM: HandshakeViewModel?
    private var timelineVM: TimelineViewModel?
    private var networkService: NetworkService?

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
        } catch {
            print("Initiate failed: \(error)")
        }
    }

    func respondToHandshake(uri: String) {
        guard let state = appState else { return }
        let vm = HandshakeViewModel(appState: state)
        handshakeVM = vm
        do {
            let pubKeyData = try vm.respond(to: uri)
            updateHandshakeState(from: vm)
            // In a real two-device flow, pubKeyData would be sent back
            // to the initiator via the network. For the POC, the initiator
            // receives it via receiveResponse.
            _ = pubKeyData
        } catch {
            print("Respond failed: \(error)")
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
            try vm.compose(data: data, burnAfter: burnAfter)
            timelineEntries = vm.entries
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
                self?.reloadTimeline()
            }
        }

        service.onSyncCompleted = { [weak self] peerID in
            DispatchQueue.main.async {
                self?.reloadTimeline()
            }
        }

        do {
            try service.start()
            networkRunning = true
            networkError = nil
        } catch {
            networkError = "\(error)"
        }
    }

    func stopNetwork() {
        networkService?.stop()
        networkService = nil
        networkRunning = false
    }
}
