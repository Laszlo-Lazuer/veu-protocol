import SwiftUI
import Combine
import BackgroundTasks
import LocalAuthentication
import UserNotifications
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
final class AppCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

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
            let trimmed = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: "veu.relayURL")
            } else {
                UserDefaults.standard.set(trimmed, forKey: "veu.relayURL")
            }
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

    // MARK: - Voice Call State
    @Published var showCallOverlay = false
    @Published var showIncomingCall = false
    @Published var callPeerName: String = ""
    @Published var callStatusText: String = ""
    @Published var incomingCallerName: String = ""
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var isInVoiceRoom = false
    @Published var activeVoiceRoomID: String?
    @Published var voiceRoomParticipants: [String] = []

    private var voiceCallManager: VoiceCallManager?

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
    private var cancellables = Set<AnyCancellable>()
    private var pendingRelayArtifacts: [String: String] = [:]

    // MARK: - Bootstrap

    func bootstrap(autoStartNetwork: Bool = true, requestNotifications: Bool = true) {
        do {
            let state = try AppState.bootstrap()
            let applyBootstrap = {
                self.appState = state
                self.reloadTimeline()
                if requestNotifications {
                    self.requestNotificationPermission()
                }
                if autoStartNetwork, state.activeCircleID != nil {
                    self.startNetwork()
                }
            }

            if Thread.isMainThread {
                applyBootstrap()
            } else {
                DispatchQueue.main.sync(execute: applyBootstrap)
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
            
            // Bring the new circle online immediately after a successful handshake.
            let shouldRestartNetwork = networkService?.isRunning == true || networkRunning
            startNetwork(forceRestart: shouldRestartNetwork)
            networkLog.append(shouldRestartNetwork ? "🔄 Network restarted with new circle" : "🟢 Network started for new circle")
            
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
            trackRelayArtifact(cid: result.cid, kind: "post")
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
            trackRelayArtifact(cid: result.cid, kind: "message")
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

    /// Open an existing DM or create a new (empty) one and navigate to it.
    func openOrCreateDM(peerDeviceID: String, peerCallsign: String) {
        if !conversations.contains(where: { $0.id == peerDeviceID }) {
            let dm = Conversation(
                id: peerDeviceID,
                type: .dm(peerDeviceID: peerDeviceID, peerCallsign: peerCallsign),
                lastMessage: nil,
                lastTimestamp: nil,
                unreadCount: 0
            )
            conversations.append(dm)
        }
        activeConversationID = peerDeviceID
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
            let result = try vm.compose(data: data, artifactType: "reaction")
            trackRelayArtifact(cid: result.cid, kind: "reaction")
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
            let result = try vm.compose(data: data, artifactType: "comment")
            trackRelayArtifact(cid: result.cid, kind: "comment")
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

    func startNetwork(forceRestart: Bool = false) {
        guard let state = appState else { return }
        if !forceRestart, let service = networkService, service.isRunning {
            networkRunning = true
            networkError = nil
            activeTransport = service.activeTransport ?? activeTransport
            return
        }

        if networkService != nil {
            networkService?.stop()
            networkService = nil
        }

        let trimmedRelay = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relay = RelayDefaults.effectiveRelayURL(from: relayURL) else {
            networkError = "Invalid relay URL"
            activeTransport = "Offline"
            networkLog.append("🔴 Invalid relay URL: \(trimmedRelay)")
            return
        }
        let service = NetworkService(appState: state, relayURL: relay)
        networkService = service

        service.onArtifactReceived = { [weak self] cid, circleID, transport in
            DispatchQueue.main.async {
                self?.syncedCount += 1
                self?.networkLog.append("📥 Received artifact \(String(cid.prefix(8)))… via \(transport)")
                self?.reloadTimeline()
                self?.fireVagueNotification()
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

        service.onVoiceCallReceived = { [weak self] payload in
            DispatchQueue.main.async {
                self?.handleVoiceSignal(payload)
            }
        }

        service.onRelayDeliveryUpdated = { [weak self] update in
            DispatchQueue.main.async {
                self?.handleRelayDelivery(update)
            }
        }

        do {
            try service.start()
            networkRunning = true
            networkError = nil
            activeTransport = service.activeTransport ?? "Connecting…"
            networkLog.append("🟢 Mesh started (circle: \(state.activeCircleID?.prefix(8) ?? "?")…)")
            networkLog.append("🌐 Relay: \(relay.absoluteString)")
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

    private func trackRelayArtifact(cid: String, kind: String) {
        pendingRelayArtifacts[cid] = kind
        if networkRunning {
            networkLog.append("📤 Queued \(kind) \(String(cid.prefix(8)))… for relay sync")
        }
    }

    private func handleRelayDelivery(_ update: RelayDeliveryUpdate) {
        let cidPrefix = String(update.cid.prefix(8))
        let kind = pendingRelayArtifacts.removeValue(forKey: update.cid) ?? "artifact"

        switch update.status {
        case .accepted:
            networkLog.append("✅ Relay accepted \(kind) \(cidPrefix)…")
        case .duplicate:
            networkLog.append("ℹ️ Relay already had \(kind) \(cidPrefix)…")
        case .rejected:
            let detail = update.detail ?? "Unknown rejection"
            networkLog.append("🔴 Relay rejected \(kind) \(cidPrefix)…: \(detail)")
            sealError = "Relay rejected \(kind): \(detail)"
        }
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

    // MARK: - Local Notifications

    /// Request notification permission on first launch.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[Notifications] Permission error: \(error)")
            }
            print("[Notifications] Permission granted: \(granted)")
        }
    }

    /// Present notification banners even while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Fire a vague local notification for new activity.
    /// Intentionally reveals nothing about sender, content, or circle.
    private func fireVagueNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Veu"
        content.body = "New activity in your Circle"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // fire immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notifications] Failed to fire: \(error)")
            }
        }
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

    // MARK: - Voice Calls

    /// Initialize the voice call manager and wire it to the network.
    func setupVoiceCallManager() {
        guard let state = appState else { return }
        let manager = VoiceCallManager()
        manager.deviceID = state.identity.deviceID
        manager.callsign = state.identity.callsign
        if let circleID = state.activeCircleID {
            manager.circleID = circleID
            if let circleKey = state.circleKeys[circleID] {
                manager.circleKey = circleKey.keyData
            }
        }
        manager.signingKey = try? state.identity.signingPrivateKey
        manager.sendSignal = { [weak self] payload in
            self?.sendVoiceSignal(payload)
        }
        manager.sendAudioFrame = { [weak self] frame in
            self?.sendVoiceFrame(frame)
        }
        self.voiceCallManager = manager

        // Observe state changes
        manager.$state.receive(on: DispatchQueue.main).sink { [weak self] callState in
            self?.updateCallUI(callState)
        }.store(in: &cancellables)
    }

    /// Start a 1:1 voice call to a DM conversation peer.
    func startVoiceCall(conversationID: String) {
        if voiceCallManager == nil { setupVoiceCallManager() }
        guard let manager = voiceCallManager else { return }

        if let conv = conversations.first(where: { $0.id == conversationID }),
           case .dm(let deviceID, let callsign) = conv.type {
            _ = manager.startCall(to: deviceID)
            callPeerName = callsign
            callStatusText = "Ringing…"
            showCallOverlay = true
        }
    }

    /// Toggle voice room for the circle.
    func toggleVoiceRoom() {
        if voiceCallManager == nil { setupVoiceCallManager() }
        guard let manager = voiceCallManager else { return }

        if isInVoiceRoom, let roomID = activeVoiceRoomID {
            manager.leaveRoom(roomID: roomID)
        } else if let circleID = appState?.activeCircleID {
            if let roomID = activeVoiceRoomID {
                manager.joinRoom(roomID: roomID, circleID: circleID)
            } else {
                _ = manager.openRoom(circleID: circleID)
            }
        }
    }

    /// Accept an incoming call.
    func acceptIncomingCall() {
        voiceCallManager?.acceptCall()
        showIncomingCall = false
    }

    /// Decline an incoming call.
    func declineIncomingCall() {
        voiceCallManager?.declineCall()
        showIncomingCall = false
    }

    /// End the current call.
    func endVoiceCall() {
        voiceCallManager?.endCall()
    }

    /// Toggle mute.
    func toggleMute() {
        isMuted.toggle()
        voiceCallManager?.setMuted(isMuted)
    }

    /// Toggle speaker.
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        voiceCallManager?.setSpeaker(isSpeakerOn)
    }

    /// Handle an incoming voice signal from the Ghost Network.
    func handleVoiceSignal(_ payload: GhostMessage.VoiceCallPayload) {
        if voiceCallManager == nil { setupVoiceCallManager() }

        // Audio frames need decryption before passing to VoiceCallManager
        if payload.action == .audioFrame, let encryptedData = payload.audioFrameData {
            guard let appState = appState,
                  let circleID = appState.activeCircleID,
                  let circleKey = appState.circleKeys[circleID],
                  let callID = currentCallID else { return }

            let transport = VoiceFrameTransport(circleKey: circleKey.keyData, callID: callID)
            guard let decrypted = try? transport.decrypt(frame: encryptedData) else { return }

            // Replace the encrypted audioFrameData with decrypted data
            var decryptedPayload = payload
            decryptedPayload.audioFrameData = decrypted
            voiceCallManager?.handleVoiceSignal(decryptedPayload)
        } else {
            voiceCallManager?.handleVoiceSignal(payload)
        }
    }

    /// Handle a received encrypted audio frame.
    func handleReceivedAudioFrame(_ frameData: Data) {
        voiceCallManager?.handleReceivedAudioFrame(frameData)
    }

    private func sendVoiceSignal(_ payload: GhostMessage.VoiceCallPayload) {
        guard let ghostNode = networkService?.meshNode?.ghostNode else { return }
        let msg = GhostMessage.voiceCall(payload)
        ghostNode.broadcastMessage(msg)
    }

    private func sendVoiceFrame(_ frame: Data) {
        guard let ghostNode = networkService?.meshNode?.ghostNode else { return }
        guard let appState = appState,
              let circleID = appState.activeCircleID,
              let circleKey = appState.circleKeys[circleID],
              let callID = currentCallID else { return }

        let transport = VoiceFrameTransport(circleKey: circleKey.keyData, callID: callID)
        if let encrypted = try? transport.encrypt(frame: frame) {
            ghostNode.broadcastRawData(encrypted)
        }
    }

    private var currentCallID: String? {
        guard let manager = voiceCallManager else { return nil }
        switch manager.state {
        case .active(let callID, _, _): return callID
        case .inRoom(let roomID, _): return roomID
        default: return nil
        }
    }

    private func updateCallUI(_ callState: VoiceCallState) {
        switch callState {
        case .idle:
            showCallOverlay = false
            showIncomingCall = false
            isInVoiceRoom = false
        case .outgoingRinging(_, let device):
            callPeerName = conversations.first(where: { $0.id == device })?.displayName ?? device
            callStatusText = "Ringing…"
            showCallOverlay = true
        case .incomingRinging(_, _, let callerCallsign):
            incomingCallerName = callerCallsign
            showIncomingCall = true
        case .active(_, _, let peerCallsign):
            callPeerName = peerCallsign
            callStatusText = "Connected"
            showCallOverlay = true
            showIncomingCall = false
            isInVoiceRoom = false
        case .inRoom(let roomID, let participants):
            activeVoiceRoomID = roomID
            voiceRoomParticipants = participants
            isInVoiceRoom = true
            showCallOverlay = false
        case .ended(let reason):
            callStatusText = reason
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showCallOverlay = false
                self?.showIncomingCall = false
                self?.isInVoiceRoom = false
                self?.activeVoiceRoomID = nil
            }
        }
    }

    /// Handle a background app refresh task — lightweight delta check.
    static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        let coordinator = AppCoordinator()
        coordinator.bootstrap(autoStartNetwork: false, requestNotifications: false)
        guard coordinator.appState?.activeCircleID != nil else {
            task.setTaskCompleted(success: true)
            return
        }

        task.expirationHandler = {
            coordinator.stopNetwork()
        }

        let startNetwork = {
            coordinator.startNetwork()
        }
        if Thread.isMainThread {
            startNetwork()
        } else {
            DispatchQueue.main.sync(execute: startNetwork)
        }

        guard coordinator.networkRunning else {
            task.setTaskCompleted(success: false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            coordinator.stopNetwork()
            task.setTaskCompleted(success: true)
        }
    }

    /// Handle a background processing task — full sync on Wi-Fi + charging.
    static func handleBackgroundProcessing(_ task: BGProcessingTask) {
        let coordinator = AppCoordinator()
        coordinator.bootstrap(autoStartNetwork: false, requestNotifications: false)
        guard coordinator.appState?.activeCircleID != nil else {
            task.setTaskCompleted(success: true)
            return
        }

        task.expirationHandler = {
            coordinator.stopNetwork()
        }

        let startNetwork = {
            coordinator.startNetwork()
        }
        if Thread.isMainThread {
            startNetwork()
        } else {
            DispatchQueue.main.sync(execute: startNetwork)
        }

        guard coordinator.networkRunning else {
            task.setTaskCompleted(success: false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            coordinator.stopNetwork()
            task.setTaskCompleted(success: true)
        }
    }
}
