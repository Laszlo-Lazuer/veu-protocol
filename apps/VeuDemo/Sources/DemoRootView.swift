import SwiftUI
import UIKit
import ImageIO
import VeuApp
import VeuGlaze
import VeuAuth

/// Root view with tab navigation and network lifecycle.
struct DemoRootView: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            IdentityTab(appState: appState)
                .tabItem {
                    Label("Identity", systemImage: "person.circle.fill")
                }
                .tag(0)

            HandshakeTab(appState: appState, coordinator: coordinator)
                .tabItem {
                    Label("Handshake", systemImage: "hand.wave.fill")
                }
                .tag(1)

            ChatTab(appState: appState, coordinator: coordinator)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(2)

            DemoTimelineTab(appState: appState, coordinator: coordinator)
                .tabItem {
                    Label("Timeline", systemImage: "photo.on.rectangle.angled")
                }
                .tag(3)

            NetworkTab(coordinator: coordinator)
                .tabItem {
                    Label("Network", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(4)
        }
        .tint(.green)
        .onChange(of: selectedTab) { _, newTab in
            if newTab == 2 || newTab == 3 {
                // Entering chat or timeline — prompt FaceID if not already unlocked
                if !coordinator.sessionUnlocked {
                    coordinator.performSessionUnlock { _ in }
                }
            } else {
                // Leaving protected tabs — lock so user must re-auth on return
                if coordinator.sessionUnlocked {
                    coordinator.lockSession()
                }
            }
        }
        .alert("Error", isPresented: .init(
            get: { coordinator.sealError != nil },
            set: { if !$0 { coordinator.sealError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.sealError ?? "")
        }
        .onOpenURL { url in
            coordinator.handleInviteURL(url)
            selectedTab = 1 // Switch to Handshake tab
        }
    }
}

// MARK: - Identity Tab

struct IdentityTab: View {
    let appState: AppState
    @State private var circleToDelete: String?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                AuraView(
                    seedColor: SIMD3<Float>(
                        appState.identity.auraSeedR,
                        appState.identity.auraSeedG,
                        appState.identity.auraSeedB
                    ),
                    pulse: 0.0
                )
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .shadow(color: .green.opacity(0.3), radius: 20)

                VStack(spacing: 8) {
                    Text(appState.identity.callsign)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))

                    Text("Device: \(appState.identity.deviceID)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !appState.circleIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Circles")
                            .font(.headline)
                        ForEach(appState.circleIDs, id: \.self) { id in
                            HStack {
                                Image(systemName: "circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text(String(id.prefix(8)) + "…")
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                                if appState.activeCircleID == id {
                                    Text("Active")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                try? appState.setActiveCircle(id)
                            }
                            .contextMenu {
                                if appState.activeCircleID != id {
                                    Button {
                                        try? appState.setActiveCircle(id)
                                    } label: {
                                        Label("Set Active", systemImage: "checkmark.circle")
                                    }
                                }
                                Button(role: .destructive) {
                                    circleToDelete = id
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Delete Circle", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Identity")
            .alert("Delete Circle?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {
                    circleToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let id = circleToDelete {
                        try? appState.removeCircle(id)
                    }
                    circleToDelete = nil
                }
            } message: {
                Text("This will permanently delete the circle, all its messages, and the shared encryption key. This cannot be undone.")
            }
        }
    }
}

// MARK: - Handshake Tab

struct HandshakeTab: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    EmeraldView(
                        phase: coordinator.handshakePhase,
                        progress: coordinator.handshakeProgress
                    )
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    handshakeContent

                    // Remote invite section (only when proximity handshake is idle)
                    if coordinator.handshakePhase == .idle {
                        Divider().padding(.vertical, 8)
                        inviteContent
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Emerald Handshake")
            .sheet(isPresented: $showShareSheet) {
                if let link = coordinator.inviteLink, let url = URL(string: link) {
                    ShareSheet(activityItems: [url])
                }
            }
        }
    }

    @ViewBuilder
    private var handshakeContent: some View {
        switch coordinator.handshakePhase {
        case .idle:
            VStack(spacing: 16) {
                Text("Bring both phones close together")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    coordinator.initiateHandshake()
                } label: {
                    Label("Create Circle", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    coordinator.joinHandshake()
                } label: {
                    Label("Join Circle", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

        case .initiating, .awaiting:
            ProximitySearchView(coordinator: coordinator)

        case .verifying:
            VStack(spacing: 16) {
                // Proximity distance indicator
                if let dist = coordinator.proximityDistance {
                    HStack(spacing: 8) {
                        Image(systemName: "wave.3.right")
                            .foregroundColor(.green)
                        Text(String(format: "%.0f cm", dist * 100))
                            .font(.system(.body, design: .monospaced))
                    }
                }

                if coordinator.proximityVerified {
                    Label("Proximity Verified", systemImage: "checkmark.shield.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                Text("Verify Short Code")
                    .font(.headline)
                if let code = coordinator.shortCode {
                    Text(code)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .kerning(4)
                }
                if let hex = coordinator.auraColorHex {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 60, height: 60)
                }
                HStack(spacing: 20) {
                    Button("Reject") {
                        coordinator.rejectHandshake()
                        HapticEngine.burnClick()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button("Confirm") {
                        coordinator.confirmHandshake()
                        HapticEngine.handshakeHeartbeat()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }

        case .confirmed:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                Text("Circle Created!")
                    .font(.title2)
                    .fontWeight(.bold)
                if let peer = coordinator.discoveredPeerName {
                    Text("Connected with \(peer)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("New Handshake") {
                    coordinator.resetHandshake()
                }
                .buttonStyle(.bordered)
            }

        case .deadLink:
            errorContent(message: "Dead Link expired", icon: "link.badge.plus")

        case .ghost:
            errorContent(message: "Handshake failed", icon: "xmark.octagon")
        }
    }

    private func errorContent(message: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text(message)
                .foregroundColor(.secondary)
            Button("Try Again") {
                coordinator.resetHandshake()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Remote Invite UI

    @ViewBuilder
    private var inviteContent: some View {
        switch coordinator.invitePhase {
        case .idle:
            VStack(spacing: 12) {
                Text("Or invite someone remotely")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    coordinator.generateInvite()
                } label: {
                    Label("Invite to Circle", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(appState.activeCircleID == nil)
            }

        case .depositing, .claiming:
            VStack(spacing: 12) {
                ProgressView()
                Text(coordinator.invitePhase == .depositing ? "Creating invite…" : "Claiming invite…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

        case .waitingForClaim:
            VStack(spacing: 16) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                Text("Invite Ready")
                    .font(.headline)
                Text("Share this link with the person you want to invite.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if let link = coordinator.inviteLink {
                    Text(link)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }

                HStack(spacing: 16) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button("Cancel") {
                        coordinator.resetInvite()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

        case .verifying:
            VStack(spacing: 16) {
                Text("Verify Short Code")
                    .font(.headline)
                Text("Confirm this code matches on both devices\nvia call or message.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if let code = coordinator.inviteShortCode {
                    Text(code)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .kerning(4)
                }
                if let hex = coordinator.inviteAuraColorHex {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 60, height: 60)
                }

                HStack(spacing: 20) {
                    Button("Reject") {
                        coordinator.rejectInvite()
                        HapticEngine.burnClick()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button("Confirm") {
                        coordinator.confirmInvite()
                        HapticEngine.handshakeHeartbeat()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }

        case .confirmed:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                Text("Invite Accepted!")
                    .font(.title2)
                    .fontWeight(.bold)
                Button("Done") {
                    coordinator.resetInvite()
                }
                .buttonStyle(.bordered)
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    coordinator.resetInvite()
                }
                .buttonStyle(.bordered)
            }

        case .expired:
            VStack(spacing: 12) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                Text("Invite expired")
                    .foregroundColor(.secondary)
                Button("Create New Invite") {
                    coordinator.resetInvite()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Proximity Search Animation

struct ProximitySearchView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                // Pulsing rings
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Color.green.opacity(0.3 - Double(i) * 0.1), lineWidth: 2)
                        .scaleEffect(pulseScale + CGFloat(i) * 0.3)
                        .frame(width: 80, height: 80)
                }

                // Center device icon
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 32))
                    .foregroundColor(.green)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulseScale = 1.3
                }
            }

            Text(coordinator.proximityStatus)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let peer = coordinator.discoveredPeerName {
                Label(peer, systemImage: "person.fill.checkmark")
                    .foregroundColor(.green)
                    .font(.headline)
            }

            if let dist = coordinator.proximityDistance {
                Text(String(format: "%.0f cm", dist * 100))
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(dist <= ProximitySession.proximityThreshold ? .green : .orange)
            }

            Button("Cancel") {
                coordinator.resetHandshake()
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }
}

// MARK: - Chat Tab

struct ChatTab: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    @State private var messageText = ""
    @FocusState private var isInputFocused: Bool
    @State private var showNewDMPicker = false

    var body: some View {
        NavigationStack {
            Group {
                if !coordinator.sessionUnlocked {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("Encrypted Chat")
                            .font(.headline)
                        Text("Authenticate to view messages.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            coordinator.performSessionUnlock { _ in }
                        } label: {
                            Label("Unlock with Face ID", systemImage: "faceid")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                } else if appState.activeCircleID == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Active Circle")
                            .font(.headline)
                        Text("Complete a handshake to start chatting.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else if !coordinator.networkRunning {
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Ghost Network Offline")
                            .font(.headline)
                        Text("Start the Ghost Network to send messages.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            coordinator.startNetwork()
                        } label: {
                            Label("Start Network", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                } else if coordinator.activeConversationID == nil {
                    // Conversation list
                    ConversationListView(
                        appState: appState,
                        coordinator: coordinator,
                        showNewDMPicker: $showNewDMPicker
                    )
                } else {
                    // Active conversation chat
                    ConversationChatView(
                        appState: appState,
                        coordinator: coordinator,
                        messageText: $messageText,
                        isInputFocused: $isInputFocused
                    )
                }
            }
            .navigationTitle(conversationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if coordinator.activeConversationID != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            coordinator.activeConversationID = nil
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Chats")
                            }
                        }
                    }
                    // Call button for DMs
                    if let conv = activeConversation, case .dm = conv.type {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                coordinator.startVoiceCall(conversationID: conv.id)
                            } label: {
                                Image(systemName: "phone.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    // Voice room button for circle chat
                    if let conv = activeConversation, case .circle = conv.type {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                coordinator.toggleVoiceRoom()
                            } label: {
                                Image(systemName: coordinator.isInVoiceRoom ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                                    .foregroundColor(coordinator.isInVoiceRoom ? .green : .secondary)
                            }
                        }
                    }
                } else {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showNewDMPicker = true } label: {
                            Image(systemName: "square.and.pencil")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            .onAppear {
                coordinator.reloadChat()
            }
            .sheet(isPresented: $showNewDMPicker) {
                NewDMPickerView(appState: appState, coordinator: coordinator, isPresented: $showNewDMPicker)
            }
        }
        .overlay {
            // Voice call overlay — blocks interaction with chat behind it
            if coordinator.showCallOverlay {
                VoiceCallOverlay(coordinator: coordinator)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
        .overlay {
            // Incoming call sheet
            if coordinator.showIncomingCall {
                IncomingCallSheet(coordinator: coordinator)
                    .transition(.move(edge: .bottom))
            }
        }
    }

    private var conversationTitle: String {
        guard let convID = coordinator.activeConversationID else { return "Encrypted Chat" }
        if let conv = activeConversation {
            switch conv.type {
            case .circle: return "Circle Chat"
            case .dm(_, let callsign): return callsign
            }
        }
        return "Chat"
    }

    private var activeConversation: Conversation? {
        coordinator.conversations.first { $0.id == coordinator.activeConversationID }
    }
}

// MARK: - Conversation List

struct ConversationListView: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    @Binding var showNewDMPicker: Bool

    var body: some View {
        List {
            // Voice room banner (if active)
            if coordinator.activeVoiceRoomID != nil {
                VoiceRoomBanner(coordinator: coordinator)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            ForEach(coordinator.conversations) { conv in
                Button {
                    coordinator.activeConversationID = conv.id
                } label: {
                    ConversationRow(conversation: conv)
                }
                .buttonStyle(.plain)
            }

            if coordinator.conversations.count <= 1 {
                VStack(spacing: 8) {
                    Text("Start a conversation")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button {
                        showNewDMPicker = true
                    } label: {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 44, height: 44)
                Image(systemName: avatarIcon)
                    .foregroundColor(.white)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let ts = conversation.lastTimestamp {
                        Text(ts, style: .relative)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                if let msg = conversation.lastMessage {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        switch conversation.type {
        case .circle: return "Circle Chat"
        case .dm(_, let callsign): return callsign
        }
    }

    private var avatarIcon: String {
        switch conversation.type {
        case .circle: return "person.3.fill"
        case .dm: return "person.fill"
        }
    }

    private var avatarColor: Color {
        switch conversation.type {
        case .circle: return Color(red: 0.22, green: 0.58, blue: 0.36)
        case .dm: return Color(red: 0.35, green: 0.55, blue: 0.70)
        }
    }
}

// MARK: - Conversation Chat View

struct ConversationChatView: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    @Binding var messageText: String
    var isInputFocused: FocusState<Bool>.Binding

    private var recipientDeviceID: String? {
        guard let convID = coordinator.activeConversationID,
              let conv = coordinator.conversations.first(where: { $0.id == convID }) else { return nil }
        if case .dm(let deviceID, _) = conv.type { return deviceID }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(coordinator.activeConversationMessages) { msg in
                            ChatBubble(message: msg, myCallsign: appState.identity.callsign) { emoji in
                                coordinator.sendReaction(emoji: emoji, targetCID: msg.id)
                            }
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: coordinator.activeConversationMessages.count) { _, _ in
                    if let last = coordinator.activeConversationMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 12) {
                TextField("Message…", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused(isInputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .submitLabel(.done)
                    .onSubmit { isInputFocused.wrappedValue = false }

                Button {
                    let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    coordinator.sendMessage(text, recipientDeviceID: recipientDeviceID)
                    messageText = ""
                    HapticEngine.vueHum()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .green)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }
}

// MARK: - New DM Picker

struct NewDMPickerView: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    @Binding var isPresented: Bool

    /// Circle members excluding the local user.
    private var otherMembers: [AppCoordinator.CircleMember] {
        let myID = appState.identity.deviceID
        return coordinator.circleMembers.filter { $0.id != myID }
    }

    var body: some View {
        NavigationStack {
            List {
                if otherMembers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No circle members found")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(otherMembers) { member in
                        Button {
                            // Create DM conversation if it doesn't exist yet
                            coordinator.openOrCreateDM(peerDeviceID: member.id, peerCallsign: member.callsign)
                            isPresented = false
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color(red: 0.35, green: 0.55, blue: 0.70))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "person.fill")
                                        .foregroundColor(.white)
                                }
                                Text(member.callsign)
                                    .font(.system(size: 16, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

// MARK: - Voice Room Banner

struct VoiceRoomBanner: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundColor(.green)
                .font(.system(size: 20))
                .symbolEffect(.variableColor.iterative)

            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Room Active")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Text("\(coordinator.voiceRoomParticipants.count) participant\(coordinator.voiceRoomParticipants.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            Button {
                coordinator.toggleVoiceRoom()
            } label: {
                Text(coordinator.isInVoiceRoom ? "Leave" : "Join")
                    .font(.subheadline.bold())
                    .foregroundColor(coordinator.isInVoiceRoom ? .red : .green)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Voice Call Overlay (In-call HUD)

struct VoiceCallOverlay: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Top call bar
            VStack(spacing: 8) {
                Text(coordinator.callPeerName)
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Text(coordinator.callStatusText)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.top, 60)

            Spacer()

            // Aura circle
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 160, height: 160)
                Circle()
                    .fill(Color.green.opacity(0.25))
                    .frame(width: 120, height: 120)
                Image(systemName: "person.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
            }

            Spacer()

            // Controls
            HStack(spacing: 40) {
                CallControlButton(
                    icon: coordinator.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: coordinator.isMuted ? "Unmute" : "Mute",
                    isActive: coordinator.isMuted
                ) {
                    coordinator.toggleMute()
                }

                CallControlButton(
                    icon: "phone.down.fill",
                    label: "End",
                    isDestructive: true
                ) {
                    coordinator.endVoiceCall()
                }

                CallControlButton(
                    icon: coordinator.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                    label: coordinator.isSpeakerOn ? "Speaker" : "Speaker",
                    isActive: coordinator.isSpeakerOn
                ) {
                    coordinator.toggleSpeaker()
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
        .ignoresSafeArea()
    }
}

struct CallControlButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(backgroundColor)
                        .frame(width: 64, height: 64)
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundColor(iconColor)
                }
                Text(label)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        if isDestructive { return .red }
        if isActive { return .white.opacity(0.3) }
        return .white.opacity(0.12)
    }

    private var iconColor: Color {
        if isDestructive { return .white }
        return .white
    }
}

// MARK: - Incoming Call Sheet

struct IncomingCallSheet: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                // Caller info
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 100, height: 100)
                    Image(systemName: "person.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                }
                Text(coordinator.incomingCallerName)
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("Incoming Encrypted Call")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))

                // Accept / Decline
                HStack(spacing: 60) {
                    Button {
                        coordinator.declineIncomingCall()
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 64, height: 64)
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                            }
                            Text("Decline")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        coordinator.acceptIncomingCall()
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 64, height: 64)
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                            }
                            Text("Accept")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.5))
        .ignoresSafeArea()
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage
    var myCallsign: String = ""
    var onReaction: ((String) -> Void)?
    @State private var showReactionPicker = false

    private static let reactionEmojis = ["❤️", "😂", "👍", "😮", "🙏", "😢"]

    var body: some View {
        HStack {
            if message.isMe { Spacer(minLength: 60) }

            VStack(alignment: message.isMe ? .trailing : .leading, spacing: 4) {
                if !message.isMe {
                    Text(message.sender)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                }

                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundColor(message.isMe ? .white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(message.isMe
                                ? Color(red: 0.22, green: 0.58, blue: 0.36)
                                : Color(.systemGray5))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: message.isMe
                        ? Color(red: 0.31, green: 0.78, blue: 0.47).opacity(0.6)
                        : Color(white: 0.75).opacity(0.5),
                        radius: 3, x: 0, y: 0)
                    .shadow(color: message.isMe
                        ? Color(red: 0.31, green: 0.78, blue: 0.47).opacity(0.35)
                        : Color(white: 0.70).opacity(0.3),
                        radius: 8, x: 0, y: 0)
                    .shadow(color: message.isMe
                        ? Color(red: 0.31, green: 0.78, blue: 0.47).opacity(0.15)
                        : Color(white: 0.65).opacity(0.15),
                        radius: 16, x: 0, y: 0)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: message.isMe ? .topLeading : .topTrailing) {
                        if !message.reactions.isEmpty {
                            ReactionBadgeRow(reactions: message.reactions, myCallsign: myCallsign) { emoji in
                                onReaction?(emoji)
                            }
                            .fixedSize()
                            .offset(x: message.isMe ? -8 : 8, y: -12)
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.3) {
                        guard !message.isMe else { return }
                        showReactionPicker = true
                        HapticEngine.vueHum()
                    }

                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .overlay(alignment: message.isMe ? .topTrailing : .topLeading) {
                if showReactionPicker {
                    ReactionPicker(emojis: Self.reactionEmojis) { emoji in
                        showReactionPicker = false
                        onReaction?(emoji)
                    }
                    .fixedSize()
                    .offset(y: -44)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .background {
                // Dismiss layer — covers full screen when picker is open
                if showReactionPicker {
                    Color.black.opacity(0.01)
                        .ignoresSafeArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture { showReactionPicker = false }
                }
            }

            if !message.isMe { Spacer(minLength: 60) }
        }
        .animation(.spring(response: 0.25), value: showReactionPicker)
    }
}

// MARK: - Reaction Picker

struct ReactionPicker: View {
    let emojis: [String]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(emojis, id: \.self) { emoji in
                Button {
                    onSelect(emoji)
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

// MARK: - Reaction Badge Row

struct ReactionBadgeRow: View {
    let reactions: [String: [String]]
    var myCallsign: String = ""
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, senders in
                let isMine = senders.contains(myCallsign)
                Button {
                    onTap(emoji)
                } label: {
                    HStack(spacing: 1) {
                        Text(emoji)
                            .font(.caption2)
                        if senders.count > 1 {
                            Text("\(senders.count)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(isMine ? Color(red: 0.22, green: 0.58, blue: 0.36).opacity(0.55) : Color(.systemGray3))
                    .clipShape(Capsule())
                    .overlay(
                        isMine ? Capsule().stroke(Color(red: 0.31, green: 0.78, blue: 0.47).opacity(0.6), lineWidth: 1) : nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Timeline Tab

struct DemoTimelineTab: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    @State private var showCapture = false
    @State private var fullscreenImage: UIImage?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                Group {
                    if appState.activeCircleID == nil {
                        emptyStateView(
                            icon: "circle.dashed",
                            title: "No Active Circle",
                            subtitle: "Complete a handshake first."
                        )
                    } else if coordinator.timelineEntries.isEmpty {
                        emptyStateView(
                            icon: "photo.on.rectangle.angled",
                            title: "No Artifacts",
                            subtitle: "Capture a photo or type a message to seal."
                        )
                    } else {
                        timelineFeed(viewportHeight: geo.size.height)
                    }
                }
            }
            .navigationTitle("Timeline")
            .toolbar {
                if appState.activeCircleID != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showCapture = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showCapture) {
                CaptureSheet(coordinator: coordinator, isPresented: $showCapture)
            }
            .fullScreenCover(item: Binding<IdentifiableImage?>(
                get: { fullscreenImage.map { IdentifiableImage(image: $0) } },
                set: { fullscreenImage = $0?.image }
            )) { item in
                FullscreenImageViewer(image: item.image) {
                    fullscreenImage = nil
                }
            }
        }
    }
    
    @ViewBuilder
    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func timelineFeed(viewportHeight: CGFloat) -> some View {
        let cardHeight = viewportHeight * 0.65
        let peekAmount: CGFloat = 40
        
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 16) {
                ForEach(coordinator.timelineEntries, id: \.cid) { entry in
                    timelineCard(entry: entry, height: cardHeight)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, peekAmount / 2)
        }
    }
    
    @ViewBuilder
    private func timelineCard(entry: TimelineEntry, height: CGFloat) -> some View {
        let seedColor = SIMD3<Float>(
            entry.glazeSeedColor.r,
            entry.glazeSeedColor.g,
            entry.glazeSeedColor.b
        )
        
        VStack(spacing: 8) {
            // Check if this is a targeted post the user can't reveal (FOMO skeleton)
            if entry.isTargeted && !entry.canReveal {
                fomoSkeletonCard(entry: entry, height: height, seedColor: seedColor)
            } else {
                revealableCard(entry: entry, height: height, seedColor: seedColor)
            }
            
            // Interaction bar (reactions + comment toggle)
            TimelineInteractionBar(
                entry: entry,
                comments: coordinator.commentsByPostCID[entry.cid] ?? [],
                reactions: coordinator.reactionsByPostCID[entry.cid] ?? [:],
                coordinator: coordinator
            )
        }
    }
    
    @ViewBuilder
    private func revealableCard(entry: TimelineEntry, height: CGFloat, seedColor: SIMD3<Float>) -> some View {
        ZStack {
            // Content layer
            Group {
                if let data = entry.plaintextData,
                   let payload = try? JSONDecoder().decode(PostPayload.self, from: data),
                   let uiImage = UIImage(data: payload.imageData) {
                    // Photo with optional caption
                    VStack(spacing: 0) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(height: payload.caption != nil ? height - 48 : height)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { fullscreenImage = uiImage }
                        if let caption = payload.caption {
                            Text(caption)
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemBackground))
                        }
                    }
                } else if let data = entry.plaintextData,
                          let uiImage = UIImage(data: data) {
                    // Raw image (legacy / no caption)
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .contentShape(Rectangle())
                        .onTapGesture { fullscreenImage = uiImage }
                } else if let data = entry.plaintextData,
                          let text = String(data: data, encoding: .utf8) {
                    VStack {
                        Spacer()
                        Text(text)
                            .font(.title2)
                            .padding(20)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                    .background(Color(.systemBackground))
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(height: height)
            
            // Sender avatar + name — top left
            VStack {
                HStack {
                    if let callsign = entry.senderCallsign {
                        HStack(spacing: 6) {
                            AuraView(seedColor: seedColor, pulse: 0.15)
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())
                            Text(callsign)
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .clipShape(Capsule())
                        .padding(10)
                    }
                    Spacer()
                }
                Spacer()
                // Transport badge + timestamp — bottom right
                HStack(spacing: 6) {
                    Spacer()
                    if let transport = entry.receivedVia {
                        Text(transportBadge(transport))
                            .font(.caption2)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial.opacity(0.7))
                            .clipShape(Capsule())
                    }
                    if let date = entry.createdAt {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial.opacity(0.7))
                            .clipShape(Capsule())
                            .padding(10)
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .vueToggle(
            seedColor: seedColor,
            sessionUnlocked: coordinator.sessionUnlocked,
            isVaultMode: false,
            canReveal: entry.canReveal,
            onReveal: { HapticEngine.vueHum() },
            onGlaze: { HapticEngine.burnClick() }
        )
    }
    
    @ViewBuilder
    private func fomoSkeletonCard(entry: TimelineEntry, height: CGFloat, seedColor: SIMD3<Float>) -> some View {
        // FOMO skeleton: animated Aura with fake identity for non-recipients
        let fomoSeed = fomoSeedColor(for: entry.cid)
        let fakeCallsign = fomoCallsign(for: entry.cid)
        
        ZStack(alignment: .bottomLeading) {
            // Full animated Aura background
            AuraView(seedColor: fomoSeed, pulse: 0.3)
            
            // Fake sender info
            HStack(spacing: 8) {
                // Mini-Aura avatar with different seed
                AuraView(seedColor: fomoSeed, pulse: 0.2)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                
                Text(fakeCallsign)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                
                Spacer()
                
                // Lock indicator
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(12)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    
    /// Map transport name to a display badge.
    private func transportBadge(_ transport: String) -> String {
        switch transport {
        case "Local":  return "📶 Local"
        case "Mesh":   return "🔗 Mesh"
        case "Global": return "📡 Relay"
        default:       return "❓ \(transport)"
        }
    }

    /// Derive a deterministic but obfuscated seed color for FOMO skeleton
    private func fomoSeedColor(for cid: String) -> SIMD3<Float> {
        let hash = cid.data(using: .utf8)!.withUnsafeBytes { bytes in
            var h: UInt64 = 5381
            for byte in bytes {
                h = ((h << 5) &+ h) &+ UInt64(byte)
            }
            return h
        }
        return SIMD3<Float>(
            Float((hash >> 16) & 0xFF) / 255.0,
            Float((hash >> 8) & 0xFF) / 255.0,
            Float(hash & 0xFF) / 255.0
        )
    }
    
    /// Derive a deterministic fake callsign for FOMO skeleton
    private func fomoCallsign(for cid: String) -> String {
        let hash = cid.data(using: .utf8)!.withUnsafeBytes { bytes in
            var h: UInt64 = 5381
            for byte in bytes {
                h = ((h << 5) &+ h) &+ UInt64(byte)
            }
            return h
        }
        return String(format: "%08X", UInt32(truncatingIfNeeded: hash >> 32))
    }
}

// MARK: - Timeline Interaction Bar

struct TimelineInteractionBar: View {
    let entry: TimelineEntry
    let comments: [Comment]
    let reactions: [String: [String]]
    @ObservedObject var coordinator: AppCoordinator
    @State private var showReactionPicker = false
    @State private var showComments = false
    @State private var commentText = ""

    private static let reactionEmojis = ["❤️", "😂", "👍", "😮", "🙏", "😢"]

    var body: some View {
        VStack(spacing: 4) {
            // Reaction badges (if any)
            if !reactions.isEmpty {
                HStack(spacing: 4) {
                    ReactionBadgeRow(reactions: reactions, myCallsign: coordinator.appState?.identity.callsign ?? "") { emoji in
                        coordinator.sendReaction(emoji: emoji, targetCID: entry.cid)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
            }

            // Reaction + comment action row
            HStack(spacing: 20) {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        showReactionPicker.toggle()
                    }
                    HapticEngine.vueHum()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.3)) {
                        showComments.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(.title3)
                        if !comments.isEmpty {
                            Text("\(comments.count)")
                                .font(.caption2.bold())
                        }
                    }
                    .foregroundColor(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            // Reaction picker
            if showReactionPicker {
                ReactionPicker(emojis: Self.reactionEmojis) { emoji in
                    showReactionPicker = false
                    coordinator.sendReaction(emoji: emoji, targetCID: entry.cid)
                }
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.scale.combined(with: .opacity))
            }

            // Comment section
            if showComments {
                VStack(spacing: 8) {
                    ForEach(comments) { comment in
                        HStack(alignment: .top, spacing: 8) {
                            Text(comment.sender)
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                            Text(comment.text)
                                .font(.caption)
                            Spacer()
                            Text(comment.timestamp, style: .relative)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }

                    // Comment input
                    HStack(spacing: 8) {
                        TextField("Comment…", text: $commentText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())

                        Button {
                            let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            coordinator.sendComment(text: text, targetCID: entry.cid)
                            commentText = ""
                            HapticEngine.vueHum()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundColor(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .green)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25), value: showReactionPicker)
    }
}

// MARK: - Capture Sheet

struct CaptureSheet: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var isPresented: Bool
    @State private var capturedData: Data?
    @State private var capturedImage: UIImage?
    @State private var messageText = ""
    @State private var useCamera = false
    @State private var sealed = false
    @State private var burnHours: Double = 24
    @State private var selectedRecipients: Set<String> = []  // Device IDs
    @State private var showRecipientPicker = false

    // Async compression state — keeps heavy work off the main thread.
    @State private var isCompressing = false
    @State private var compressedData: Data?
    @State private var compressedSize: Int?
    @State private var compressionError: String?
    @State private var compressionTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 20) {
                if useCamera {
                    CameraCaptureView { imageData in
                        capturedData = imageData
                        capturedImage = UIImage(data: imageData)
                        useCamera = false
                        triggerCompression()
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    // Mode selector
                    HStack(spacing: 16) {
                        Button {
                            useCamera = true
                        } label: {
                            VStack {
                                Image(systemName: "camera.fill")
                                    .font(.title)
                                Text("Photo")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)

                        VStack {
                            Image(systemName: "text.bubble.fill")
                                .font(.title)
                            Text("Message")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                    }

                    // Photo preview + compression status
                    if let preview = capturedImage {
                        ZStack {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 200)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            if isCompressing {
                                Color.black.opacity(0.5)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(spacing: 8) {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Optimizing for relay…")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                            }

                            // Retake button
                            VStack {
                                HStack {
                                    Spacer()
                                    Button {
                                        capturedData = nil
                                        capturedImage = nil
                                        compressedData = nil
                                        compressedSize = nil
                                        compressionError = nil
                                        useCamera = true
                                    } label: {
                                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                                            .font(.caption)
                                            .padding(8)
                                            .background(.ultraThinMaterial)
                                            .clipShape(Circle())
                                    }
                                    .padding(8)
                                }
                                Spacer()
                            }
                        }
                        .frame(height: 200)

                        // Size info (uses cached result, never recompresses)
                        if let raw = capturedData {
                            if let size = compressedSize {
                                Label("Photo: \(formatBytes(raw.count)) → \(formatBytes(size))",
                                      systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else if let err = compressionError {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                            } else if !isCompressing {
                                Label("Photo: \(formatBytes(raw.count))",
                                      systemImage: "photo.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }

                    TextField("Enter message…", text: $messageText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                    
                    // Recipient picker
                    recipientSelector

                    VStack(alignment: .leading) {
                        Text("Burn Timer: \(Int(burnHours))h")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Slider(value: $burnHours, in: 1...168, step: 1)
                            .tint(.orange)
                    }

                    if sealed {
                        Label("Sealed & Queued for Sync", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.headline)
                    } else {
                        Button {
                            sealContent()
                        } label: {
                            Label(isCompressing ? "Processing…" : "Seal", systemImage: "lock.shield")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled((capturedData == nil && messageText.isEmpty) || isCompressing)
                    }
                }

            }
            .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Compose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .sheet(isPresented: $showRecipientPicker) {
                recipientPickerSheet
            }
        }
    }

    /// Kick off compression on a background thread. Only recompresses
    /// when the raw image data changes — typing a caption won't retrigger.
    private func triggerCompression() {
        compressionTask?.cancel()
        guard let raw = capturedData else { return }

        isCompressing = true
        compressedData = nil
        compressedSize = nil
        compressionError = nil

        compressionTask = Task.detached(priority: .userInitiated) {
            do {
                let caption = ""  // Preview uses empty caption; seal uses actual caption.
                let burnAfter = Int(Date().timeIntervalSince1970) + Int(24 * 3600)
                let compressed = try await MainActor.run {
                    try compressForSending(raw, caption: caption, burnAfter: burnAfter, targetRecipients: nil)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    compressedData = compressed
                    compressedSize = compressed.count
                    isCompressing = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    compressionError = error.localizedDescription
                    isCompressing = false
                }
            }
        }
    }
    
    @ViewBuilder
    private var recipientSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recipients")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showRecipientPicker = true
                } label: {
                    Label(recipientLabel, systemImage: selectedRecipients.isEmpty ? "person.2" : "person.2.fill")
                        .font(.subheadline)
                }
            }
            
            if !selectedRecipients.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(selectedRecipients), id: \.self) { deviceID in
                            if let member = coordinator.circleMembers.first(where: { $0.id == deviceID }) {
                                HStack(spacing: 4) {
                                    Text(member.callsign)
                                        .font(.caption.bold())
                                    Button {
                                        selectedRecipients.remove(deviceID)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.2))
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var recipientLabel: String {
        if selectedRecipients.isEmpty {
            return "Everyone"
        } else {
            return "\(selectedRecipients.count) selected"
        }
    }
    
    @ViewBuilder
    private var recipientPickerSheet: some View {
        NavigationStack {
            List {
                // "Everyone" option
                Button {
                    selectedRecipients.removeAll()
                    showRecipientPicker = false
                } label: {
                    HStack {
                        Image(systemName: "person.2.fill")
                        Text("Everyone in Circle")
                        Spacer()
                        if selectedRecipients.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundColor(.green)
                        }
                    }
                }
                
                Section("Circle Members") {
                    ForEach(coordinator.circleMembers) { member in
                        // Skip self (can't send to just yourself)
                        if member.id != coordinator.appState?.identity.deviceID {
                            Button {
                                if selectedRecipients.contains(member.id) {
                                    selectedRecipients.remove(member.id)
                                } else {
                                    selectedRecipients.insert(member.id)
                                }
                            } label: {
                                HStack {
                                    Text(member.callsign)
                                        .font(.body.monospaced())
                                    Spacer()
                                    if selectedRecipients.contains(member.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Recipients")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showRecipientPicker = false }
                }
            }
        }
    }
    
    /// Compress image for a final encoded relay package budget of 2 MB.
    private func compressForSending(
        _ rawData: Data,
        caption: String,
        burnAfter: Int?,
        targetRecipients: [String]?
    ) throws -> Data {
        guard let image = UIImage(data: rawData) else { return rawData }
        guard let state = coordinator.appState,
              let circleID = state.activeCircleID else {
            throw NSError(
                domain: "DemoTimelineTab",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No active circle selected"]
            )
        }

        let circleKey = try state.activeCircleKey()
        let captionValue = caption.isEmpty ? nil : caption
        let qualityCandidates: [CGFloat] = [0.72, 0.64, 0.56, 0.48, 0.40, 0.32, 0.26, 0.22, 0.18, 0.14, 0.10]
        let sizeCandidates = dimensionCandidates(for: image)

        var bestCandidate: (data: Data, packageSize: Int)?

        for maxDimension in sizeCandidates {
            let preparedImage = processedImageForSending(image, maxDimension: maxDimension)

            for quality in qualityCandidates {
                guard let jpegData = preparedImage.jpegData(compressionQuality: quality) else { continue }
                let candidate = stripMetadata(from: jpegData) ?? jpegData
                let postData = try encodePostPayload(imageData: candidate, caption: captionValue)
                let packageSize = try RelayPostBudget.encodedPackageSize(
                    forPostData: postData,
                    circleID: circleID,
                    circleKey: circleKey,
                    senderDeviceID: state.identity.deviceID,
                    burnAfter: burnAfter,
                    targetRecipients: targetRecipients
                )

                if bestCandidate == nil || packageSize < bestCandidate!.packageSize {
                    bestCandidate = (candidate, packageSize)
                }

                if packageSize <= RelayPostBudget.targetEncodedPackageBytes {
                    return candidate
                }
            }
        }

        // Always return the best candidate — local/mesh have no size limit and
        // the relay hard limit (5 MB payload) is well above the 2 MB target.
        if let best = bestCandidate {
            print("[Compress] Best candidate \(formatBytes(best.packageSize)) exceeds 2 MB relay target; using anyway")
            return best.data
        }

        return rawData
    }

    private func dimensionCandidates(for image: UIImage) -> [CGFloat] {
        let originalLongestEdge = max(image.size.width, image.size.height)
        let candidates: [CGFloat] = [1080, 960, 840, 720, 600, 540, 480]
        return candidates.filter { $0 < originalLongestEdge } + [min(originalLongestEdge, 1080)]
            .reduce(into: [CGFloat]()) { result, value in
                if !result.contains(value) {
                    result.append(value)
                }
            }
            .sorted(by: >)
    }

    private func processedImageForSending(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale: CGFloat
        if max(size.width, size.height) > maxDimension {
            scale = maxDimension / max(size.width, size.height)
        } else {
            scale = 1.0
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }

        let cropped = randomMicroCrop(resized)
        return injectSensorNoise(cropped)
    }

    private func encodePostPayload(imageData: Data, caption: String?) throws -> Data {
        try JSONEncoder().encode(PostPayload(imageData: imageData, caption: caption))
    }

    /// Crop 1-4 random pixels from each edge to break PRNU spatial alignment.
    private func randomMicroCrop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = cg.width, h = cg.height
        guard w > 16, h > 16 else { return image }
        let top = Int.random(in: 1...4)
        let left = Int.random(in: 1...4)
        let bottom = Int.random(in: 1...4)
        let right = Int.random(in: 1...4)
        let rect = CGRect(x: left, y: top, width: w - left - right, height: h - top - bottom)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Add subtle Gaussian noise (σ≈2.5) to pixel values, destroying PRNU patterns.
    private func injectSensorNoise(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = cg.width, h = cg.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Box-Muller Gaussian noise, σ ≈ 2.5 — invisible but breaks PRNU correlation
        let sigma: Double = 2.5
        let count = w * h * 4
        var i = 0
        while i < count {
            // Skip alpha channel (every 4th byte)
            for ch in 0..<3 {
                let u1 = max(Double.random(in: 0..<1), 1e-10)
                let u2 = Double.random(in: 0..<1)
                let noise = sigma * (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
                let val = Double(pixels[i + ch]) + noise
                pixels[i + ch] = UInt8(clamping: Int(val.rounded()))
            }
            i += 4
        }

        guard let noisedCG = ctx.makeImage() else { return image }
        return UIImage(cgImage: noisedCG, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Remove all EXIF/GPS/TIFF metadata from JPEG data for privacy.
    private func stripMetadata(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return nil }
        // Copy pixels but replace all metadata with an empty dictionary
        CGImageDestinationAddImageFromSource(dest, source, 0, [
            kCGImageDestinationMetadata: NSDictionary()
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    private func sealContent() {
        let caption = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let burnEpoch = Int(Date().timeIntervalSince1970) + Int(burnHours * 3600)
        
        // Convert selected recipients to array (nil = everyone)
        let targets: [String]? = selectedRecipients.isEmpty ? nil : Array(selectedRecipients)

        do {
            let data: Data
            if let imageData = capturedData {
                // Use pre-compressed data when available; fall back to on-demand compression.
                let compressed: Data
                if let cached = compressedData {
                    compressed = cached
                } else {
                    compressed = try compressForSending(
                        imageData,
                        caption: caption,
                        burnAfter: burnEpoch,
                        targetRecipients: targets
                    )
                }
                data = try encodePostPayload(imageData: compressed, caption: caption.isEmpty ? nil : caption)
            } else {
                data = Data(caption.utf8)
            }

            guard !data.isEmpty else { return }

            coordinator.sealArtifact(data: data, burnAfter: burnEpoch, targetRecipients: targets)
            HapticEngine.handshakeHeartbeat()
            sealed = true
        } catch {
            coordinator.sealError = error.localizedDescription
        }
    }
}

// MARK: - Network Tab

struct NetworkTab: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Transport status indicator
                HStack(spacing: 12) {
                    Circle()
                        .fill(coordinator.networkRunning ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.networkRunning ? "Mesh Network Active" : "Mesh Network Offline")
                            .font(.headline)
                        Text(coordinator.activeTransport)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    transportIcon
                }

                if coordinator.networkRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoRow(label: "Device ID", value: coordinator.appState?.identity.deviceID ?? "—")
                        InfoRow(label: "Active Circle", value: coordinator.appState?.activeCircleID.map { String($0.prefix(8)) + "…" } ?? "None")
                        InfoRow(label: "Transport", value: coordinator.activeTransport)
                        InfoRow(label: "Peers", value: "\(coordinator.peerCount)")
                        InfoRow(label: "Synced Artifacts", value: "\(coordinator.syncedCount)")
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)

                    Button {
                        coordinator.stopNetwork()
                    } label: {
                        Label("Stop Network", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    // Relay URL configuration
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Relay Server")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Leave blank to use the default relay: \(RelayDefaults.defaultRelayURLString)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        TextField("Default: \(RelayDefaults.defaultRelayURLString)", text: $coordinator.relayURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(.horizontal)

                    Button {
                        coordinator.startNetwork()
                    } label: {
                        Label("Start Mesh Network", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(coordinator.appState?.activeCircleID == nil)
                }

                if let error = coordinator.networkError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }

                // Debug log
                if !coordinator.networkLog.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Network Log")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(coordinator.networkLog.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.system(.caption2, design: .monospaced))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Mesh Network")
        }
    }

    @ViewBuilder
    private var transportIcon: some View {
        switch coordinator.activeTransport {
        case "Local":
            Image(systemName: "wifi")
                .foregroundColor(.green)
        case "Mesh":
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundColor(.blue)
        case "Global":
            Image(systemName: "globe")
                .foregroundColor(.purple)
        default:
            Image(systemName: "wifi.slash")
                .foregroundColor(.gray)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Fullscreen Image Viewer

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct FullscreenImageViewer: View {
    let image: UIImage
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var saved = false
    @State private var dragOffset: CGFloat = 0

    private var dismissProgress: CGFloat {
        min(abs(dragOffset) / 200, 1.0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(1.0 - dismissProgress * 0.5)

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height + (scale <= 1.0 ? dragOffset : 0))
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = lastScale * value
                        }
                        .onEnded { value in
                            lastScale = max(scale, 1.0)
                            scale = lastScale
                            if lastScale == 1.0 {
                                withAnimation(.spring()) { offset = .zero }
                                lastOffset = .zero
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if scale > 1.0 {
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            } else {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if scale > 1.0 {
                                lastOffset = offset
                            } else {
                                if abs(dragOffset) > 120 {
                                    onDismiss()
                                } else {
                                    withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1.0 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 3.0
                            lastScale = 3.0
                        }
                    }
                }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 16) {
                Button {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    saved = true
                    HapticEngine.vueHum()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                } label: {
                    Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                        .font(.title2)
                        .foregroundStyle(saved ? .green : .white.opacity(0.8))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .statusBarHidden()
    }
}

// MARK: - Color hex extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
