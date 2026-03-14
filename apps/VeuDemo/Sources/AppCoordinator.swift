import SwiftUI
import BackgroundTasks
import LocalAuthentication
import VeuApp
import VeuAuth
import VeuGlaze
import VeuGhost
import VeuMesh
import MultipeerConnectivity

// MARK: - Dev Mode Toggle
#if DEBUG
let DEV_MODE = true
#else
let DEV_MODE = false
#endif

/// Central coordinator managing app state and all service lifecycles.
final class AppCoordinator: ObservableObject {

    // MARK: - Published state

    @Published var appState: AppState?
    @Published var handshakePhase: HandshakePhase = .idle
    @Published var shortCode: String?
    @Published var auraColorHex: String?
    @Published var timelineEntries: [TimelineEntry] = []
    @Published var chatMessages: [ChatMessage] = []
    @Published var conversations: [Conversation] = []
    @Published var activeConversationID: String?
    @Published var networkRunning = false
    @Published var syncedCount = 0
    @Published var networkError: String?
    @Published var handshakeProgress: Float = 0
    @Published var peerCount = 0
    @Published var networkLog: [String] = []
    @Published var activeTransport: String = "Offline"
    @Published var relayURL: String = UserDefaults.standard.string(forKey: "veu.relayURL") ?? "" {
        didSet {
            UserDefaults.standard.set(relayURL, forKey: "veu.relayURL")
        }
    }
    @Published var sealError: String?
    
    /// Session-based unlock: FaceID once on app launch unlocks all content for the session.
    @Published var sessionUnlocked = false
    /// When session unlock was last performed (nil = never this session).
    @Published var lastUnlockTime: Date?
    
    /// Circle member for display in recipient picker.
    public struct CircleMember: Identifiable, Equatable {
        public let id: String  // deviceID
        public let callsign: String
        public let publicKeyHex: String
    }
    
    /// Members of the active circle (for recipient picker).
    @Published var circleMembers: [CircleMember] = []

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
    
    // MARK: - Session Unlock
    
    /// Perform session-level FaceID unlock. Once unlocked, content auto-reveals for the session.
    func performSessionUnlock(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Fallback: no biometrics available, unlock anyway
            DispatchQueue.main.async {
                self.sessionUnlocked = true
                self.lastUnlockTime = Date()
                completion(true)
            }
            return
        }
        
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock Veu to view your content"
        ) { success, _ in
            DispatchQueue.main.async {
                if success {
                    self.sessionUnlocked = true
                    self.lastUnlockTime = Date()
                }
                completion(success)
            }
        }
    }
    
    /// Lock the session (e.g., when app enters background for extended time).
    func lockSession() {
        sessionUnlocked = false
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
        guard let state = appState else { return }
        do {
            try vm.confirm()
            updateHandshakeState(from: vm)
            
            // Add circle members (self + peer)
            let circleID = vm.circleID
            print("[AppCoordinator] Handshake confirmed, circleID=\(circleID.prefix(8))…")
            
            // Debug: print circle key
            if let key = state.circleKeys[circleID] {
                let keyHash = key.keyData.prefix(8).map { String(format: "%02x", $0) }.joined()
                print("[AppCoordinator] CircleKey hash=\(keyHash)…")
            }
            
            // Add self as member
            try state.ledger.insertCircleMember(
                circleID: circleID,
                deviceID: state.identity.deviceID,
                publicKeyHex: state.identity.publicKeyHex,
                callsign: state.identity.callsign
            )
            
            // Add peer as member (derive callsign from their public key)
            if let peerPubKeyData = vm.peerPublicKeyData {
                let peerCallsign = Identity.deriveCallsign(from: peerPubKeyData)
                let peerDeviceID = Identity.deriveDeviceID(from: peerPubKeyData)
                try state.ledger.insertCircleMember(
                    circleID: circleID,
                    deviceID: peerDeviceID,
                    publicKeyHex: peerPubKeyData.map { String(format: "%02x", $0) }.joined(),
                    callsign: peerCallsign
                )
            }
            
            reloadTimeline()
            reloadCircleMembers()
            
            // Restart network with the new circle key
            try networkService?.restart()
            networkLog.append("🔄 Network restarted with new circle")
            
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
            timelineEntries = vm.entries.filter { $0.artifactType != "message" && $0.artifactType != "reaction" && $0.artifactType != "comment" }
            reloadChat()
            reloadCircleMembers()
        } catch {
            print("Reload failed: \(error)")
        }
    }
    
    /// Reload circle members for the active circle (for recipient picker).
    func reloadCircleMembers() {
        guard let state = appState,
              let circleID = state.activeCircleID else {
            circleMembers = []
            return
        }
        
        do {
            let members = try state.ledger.listCircleMembers(circleID: circleID)
            circleMembers = members.map { member in
                CircleMember(
                    id: member.deviceID,
                    callsign: member.callsign,
                    publicKeyHex: member.publicKeyHex
                )
            }
        } catch {
            print("Reload members failed: \(error)")
            circleMembers = []
        }
    }

    func sealArtifact(data: Data, burnAfter: Int?, targetRecipients: [String]? = nil) {
        guard let state = appState else {
            sealError = "App state not initialized"
            return
        }
        guard state.activeCircleID != nil else {
            sealError = "No active circle selected"
            return
        }
        let vm = timelineVM ?? TimelineViewModel(appState: state)
        timelineVM = vm
        do {
            let result = try vm.compose(data: data, targetRecipients: targetRecipients, burnAfter: burnAfter)
            timelineEntries = vm.entries.filter { $0.artifactType != "message" && $0.artifactType != "reaction" && $0.artifactType != "comment" }
            reloadChat()
            // Notify the mesh network so it can sync the new artifact to peers
            if let node = networkService?.meshNode, let circleID = state.activeCircleID {
                node.recordLocalArtifact()
            }
        } catch {
            sealError = "Seal failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Chat

    func sendMessage(_ text: String, recipientDeviceID: String? = nil) {
        guard let state = appState else { return }
        let vm = timelineVM ?? TimelineViewModel(appState: state)
        timelineVM = vm
        do {
            let chatPayload = ChatPayload(
                text: text,
                sender: state.identity.callsign,
                timestamp: Date().timeIntervalSince1970,
                recipientDeviceID: recipientDeviceID
            )
            let data = try JSONEncoder().encode(chatPayload)
            let targets: [String]? = recipientDeviceID.map { [$0] }
            let result = try vm.compose(data: data, artifactType: "message", targetRecipients: targets)
            timelineEntries = vm.entries.filter { $0.artifactType != "message" && $0.artifactType != "reaction" && $0.artifactType != "comment" }
            reloadChat()
            if let node = networkService?.meshNode, let circleID = state.activeCircleID {
                node.recordLocalArtifact()
            }
        } catch {
            print("Send message failed: \(error)")
        }
    }

    func reloadChat() {
        guard let state = appState else { return }
        let vm = timelineVM ?? TimelineViewModel(appState: state)
        timelineVM = vm
        do {
            try vm.reload()
            timelineEntries = vm.entries.filter { $0.artifactType != "message" && $0.artifactType != "reaction" && $0.artifactType != "comment" }
        } catch {
            print("Reload failed: \(error)")
            return
        }

        // Collect reactions keyed by target CID
        let myCallsign = state.identity.callsign
        let reactionsByCID = aggregateReactions(from: vm.entries)
        reactionsByPostCID = reactionsByCID
        commentsByPostCID = aggregateComments(from: vm.entries, myCallsign: myCallsign)

        // Also attach reactions to timeline posts
        timelineEntries = vm.entries
            .filter { $0.artifactType != "message" && $0.artifactType != "reaction" && $0.artifactType != "comment" }

        // Filter to message-type entries and decode
        chatMessages = vm.entries
            .filter { $0.artifactType == "message" }
            .compactMap { entry -> ChatMessage? in
                guard let data = entry.plaintextData,
                      let payload = try? JSONDecoder().decode(ChatPayload.self, from: data) else {
                    guard let data = entry.plaintextData,
                          let text = String(data: data, encoding: .utf8) else { return nil }
                    return ChatMessage(
                        id: entry.cid,
                        text: text,
                        sender: "Unknown",
                        timestamp: Date(),
                        isMe: false,
                        conversationID: state.activeCircleID ?? "unknown",
                        reactions: reactionsByCID[entry.cid] ?? [:]
                    )
                }
                // Determine conversation: DM uses peer device ID, circle chat uses circle ID
                let convID: String
                if let recipient = payload.recipientDeviceID {
                    // DM: conversation keyed by the *other* party
                    convID = payload.sender == myCallsign ? recipient : (entry.senderCallsign ?? payload.sender)
                } else {
                    convID = state.activeCircleID ?? "unknown"
                }
                return ChatMessage(
                    id: entry.cid,
                    text: payload.text,
                    sender: payload.sender,
                    timestamp: Date(timeIntervalSince1970: payload.timestamp),
                    isMe: payload.sender == myCallsign,
                    conversationID: convID,
                    reactions: reactionsByCID[entry.cid] ?? [:]
                )
            }
            .sorted { $0.timestamp < $1.timestamp }

        // Build conversations from messages
        buildConversations(circleID: state.activeCircleID ?? "unknown", myCallsign: myCallsign)
    }

    /// Build conversation list from current chatMessages.
    private func buildConversations(circleID: String, myCallsign: String) {
        var convMap: [String: Conversation] = [:]

        // Always include circle chat
        convMap[circleID] = Conversation(
            id: circleID,
            type: .circle,
            lastMessage: nil,
            lastTimestamp: nil,
            unreadCount: 0
        )

        for msg in chatMessages {
            let convID = msg.conversationID
            if convMap[convID] == nil {
                let convType: Conversation.ConversationType
                if convID == circleID {
                    convType = .circle
                } else {
                    // DM — the convID is the peer's callsign or device ID
                    convType = .dm(peerDeviceID: convID, peerCallsign: msg.isMe ? convID : msg.sender)
                }
                convMap[convID] = Conversation(
                    id: convID,
                    type: convType,
                    lastMessage: nil,
                    lastTimestamp: nil,
                    unreadCount: 0
                )
            }
            // Update last message (messages are sorted chronologically)
            convMap[convID]?.lastMessage = msg.text
            convMap[convID]?.lastTimestamp = msg.timestamp
        }

        // Sort: circle first, then DMs by most recent
        conversations = convMap.values.sorted { a, b in
            if case .circle = a.type { return true }
            if case .circle = b.type { return false }
            return (a.lastTimestamp ?? .distantPast) > (b.lastTimestamp ?? .distantPast)
        }
    }

    /// Messages filtered for the active conversation.
    var activeConversationMessages: [ChatMessage] {
        guard let convID = activeConversationID else { return chatMessages }
        return chatMessages.filter { $0.conversationID == convID }
    }

    // MARK: - Reactions

    func sendReaction(emoji: String, targetCID: String) {
        guard let state = appState else { return }
        let vm = timelineVM ?? TimelineViewModel(appState: state)
        timelineVM = vm
        do {
            let payload = ReactionPayload(
                emoji: emoji,
                targetCID: targetCID,
                sender: state.identity.callsign,
                timestamp: Date().timeIntervalSince1970
            )
            let data = try JSONEncoder().encode(payload)
            _ = try vm.compose(data: data, artifactType: "reaction")
            reloadChat()
            if let node = networkService?.meshNode {
                node.recordLocalArtifact()
            }
        } catch {
            print("Send reaction failed: \(error)")
        }
    }

    // MARK: - Comments

    @Published var commentsByPostCID: [String: [Comment]] = [:]
    @Published var reactionsByPostCID: [String: [String: [String]]] = [:]

    func sendComment(text: String, targetCID: String) {
        guard let state = appState else { return }
        let vm = timelineVM ?? TimelineViewModel(appState: state)
        timelineVM = vm
        do {
            let payload = CommentPayload(
                text: text,
                sender: state.identity.callsign,
                targetCID: targetCID,
                timestamp: Date().timeIntervalSince1970
            )
            let data = try JSONEncoder().encode(payload)
            _ = try vm.compose(data: data, artifactType: "comment")
            reloadChat()
            if let node = networkService?.meshNode {
                node.recordLocalArtifact()
            }
        } catch {
            print("Send comment failed: \(error)")
        }
    }

    /// Aggregate reaction artifacts into a lookup: `targetCID → { emoji → [senders] }`.
    /// Each sender keeps only their latest reaction per target. If their latest
    /// reaction matches their previous one it's treated as a toggle-off (removed).
    private func aggregateReactions(from entries: [TimelineEntry]) -> [String: [String: [String]]] {
        // Collect all reactions sorted by timestamp (entries are already chronological)
        struct R { let emoji: String; let sender: String; let target: String; let ts: TimeInterval }
        var all: [R] = []
        for entry in entries where entry.artifactType == "reaction" {
            guard let data = entry.plaintextData,
                  let payload = try? JSONDecoder().decode(ReactionPayload.self, from: data) else { continue }
            all.append(R(emoji: payload.emoji, sender: payload.sender, target: payload.targetCID, ts: payload.timestamp))
        }
        all.sort { $0.ts < $1.ts }

        // For each (target, sender) keep only the latest reaction.
        // If the latest matches the previous → toggle off (nil).
        // If different → replace with the new emoji.
        var latest: [String: [String: (emoji: String?, prev: String?)]] = [:]  // target → sender → state
        for r in all {
            let current = latest[r.target]?[r.sender]
            if current?.emoji == r.emoji {
                // Same emoji again → toggle off
                latest[r.target, default: [:]][r.sender] = (emoji: nil, prev: r.emoji)
            } else {
                // New or different emoji → set it
                latest[r.target, default: [:]][r.sender] = (emoji: r.emoji, prev: current?.emoji)
            }
        }

        // Build final result
        var result: [String: [String: [String]]] = [:]
        for (target, senders) in latest {
            for (sender, state) in senders {
                if let emoji = state.emoji {
                    result[target, default: [:]][emoji, default: []].append(sender)
                }
            }
        }
        return result
    }

    /// Aggregate comment artifacts into a lookup: `targetCID → [Comment]`.
    func aggregateComments(from entries: [TimelineEntry], myCallsign: String) -> [String: [Comment]] {
        let reactionsByCID = aggregateReactions(from: entries)
        var result: [String: [Comment]] = [:]
        for entry in entries where entry.artifactType == "comment" {
            guard let data = entry.plaintextData,
                  let payload = try? JSONDecoder().decode(CommentPayload.self, from: data) else { continue }
            let comment = Comment(
                id: entry.cid,
                text: payload.text,
                sender: payload.sender,
                timestamp: Date(timeIntervalSince1970: payload.timestamp),
                isMe: payload.sender == myCallsign,
                reactions: reactionsByCID[entry.cid] ?? [:]
            )
            result[payload.targetCID, default: []].append(comment)
        }
        // Sort each list by timestamp
        for key in result.keys {
            result[key]?.sort { $0.timestamp < $1.timestamp }
        }
        return result
    }

    // MARK: - Network

    func startNetwork() {
        guard let state = appState else { return }
        let relay = relayURL.isEmpty ? nil : URL(string: relayURL)
        let service = NetworkService(appState: state, relayURL: relay)
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

        service.onTransportChanged = { [weak self] transport in
            DispatchQueue.main.async {
                self?.activeTransport = transport
                self?.networkLog.append("🔄 Transport: \(transport)")
            }
        }

        service.onPeerConnected = { [weak self] peerID, transport in
            DispatchQueue.main.async {
                self?.peerCount += 1
                self?.networkLog.append("🔍 Peer connected via \(transport): \(peerID)")
            }
        }

        service.onPeerDisconnected = { [weak self] peerID in
            DispatchQueue.main.async {
                self?.peerCount = max(0, (self?.peerCount ?? 1) - 1)
                self?.networkLog.append("👻 Peer disconnected: \(peerID)")
            }
        }

        do {
            try service.start()
            networkRunning = true
            networkError = nil
            activeTransport = service.activeTransport ?? "Connecting…"
            networkLog.append("🟢 Mesh started (circle: \(state.activeCircleID?.prefix(8) ?? "?")…)")
            if relay != nil {
                networkLog.append("🌐 Relay: \(relayURL)")
            }
        } catch {
            networkError = "\(error)"
            activeTransport = "Offline"
            networkLog.append("🔴 Start failed: \(error)")
        }
    }

    func stopNetwork() {
        networkService?.stop()
        networkService = nil
        networkRunning = false
        activeTransport = "Offline"
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

    // MARK: - Background Tasks

    /// Schedule a background sync refresh task.
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: "com.veu.protocol.sync.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BG] Failed to schedule refresh: \(error)")
        }
    }

    /// Handle a background app refresh task — lightweight delta check.
    static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        let coordinator = AppCoordinator()
        coordinator.bootstrap()
        guard coordinator.appState?.activeCircleID != nil else {
            task.setTaskCompleted(success: true)
            return
        }

        task.expirationHandler = {
            coordinator.stopNetwork()
        }

        do {
            try coordinator.networkService?.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                coordinator.stopNetwork()
                task.setTaskCompleted(success: true)
            }
        } catch {
            task.setTaskCompleted(success: false)
        }
    }

    /// Handle a background processing task — full sync on Wi-Fi + charging.
    static func handleBackgroundProcessing(_ task: BGProcessingTask) {
        let coordinator = AppCoordinator()
        coordinator.bootstrap()
        guard coordinator.appState?.activeCircleID != nil else {
            task.setTaskCompleted(success: true)
            return
        }

        task.expirationHandler = {
            coordinator.stopNetwork()
        }

        do {
            try coordinator.networkService?.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                coordinator.stopNetwork()
                task.setTaskCompleted(success: true)
            }
        } catch {
            task.setTaskCompleted(success: false)
        }
    }
}
