import SwiftUI
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
        .alert("Error", isPresented: .init(
            get: { coordinator.sealError != nil },
            set: { if !$0 { coordinator.sealError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.sealError ?? "")
        }
    }
}

// MARK: - Identity Tab

struct IdentityTab: View {
    let appState: AppState

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
        }
    }
}

// MARK: - Handshake Tab

struct HandshakeTab: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                EmeraldView(
                    phase: coordinator.handshakePhase,
                    progress: coordinator.handshakeProgress
                )
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                handshakeContent
                Spacer()
            }
            .padding()
            .navigationTitle("Emerald Handshake")
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

    var body: some View {
        NavigationStack {
            Group {
                if appState.activeCircleID == nil {
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
                } else {
                    VStack(spacing: 0) {
                        // Messages
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(coordinator.chatMessages) { msg in
                                        ChatBubble(message: msg)
                                            .id(msg.id)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.top, 8)
                            }
                            .onChange(of: coordinator.chatMessages.count) { _ in
                                if let last = coordinator.chatMessages.last {
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
                                .focused($isInputFocused)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 20))

                            Button {
                                let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                coordinator.sendMessage(text)
                                messageText = ""
                                HapticEngine.vueHum()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .green)
                            }
                            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(.systemBackground))
                    }
                }
            }
            .navigationTitle("Encrypted Chat")
            .onAppear {
                coordinator.reloadChat()
            }
        }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage

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
                    .background(message.isMe ? Color.green : Color(.systemGray5))
                    .foregroundColor(message.isMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if !message.isMe { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Timeline Tab

struct DemoTimelineTab: View {
    let appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    @State private var showCapture = false

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
        
        // Check if this is a targeted post the user can't reveal (FOMO skeleton)
        if entry.isTargeted && !entry.canReveal {
            fomoSkeletonCard(entry: entry, height: height, seedColor: seedColor)
        } else {
            revealableCard(entry: entry, height: height, seedColor: seedColor)
        }
    }
    
    @ViewBuilder
    private func revealableCard(entry: TimelineEntry, height: CGFloat, seedColor: SIMD3<Float>) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Content layer
            Group {
                if let data = entry.plaintextData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
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
            
            // Sender info overlay (shown when revealed)
            if let callsign = entry.senderCallsign {
                HStack(spacing: 8) {
                    // Mini-Aura avatar
                    AuraView(seedColor: seedColor, pulse: 0.0)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    
                    Text(callsign)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(12)
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

// MARK: - Capture Sheet

struct CaptureSheet: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var isPresented: Bool
    @State private var capturedData: Data?
    @State private var messageText = ""
    @State private var useCamera = false
    @State private var sealed = false
    @State private var burnHours: Double = 24
    @State private var selectedRecipients: Set<String> = []  // Device IDs
    @State private var showRecipientPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if useCamera {
                    CameraCaptureView { imageData in
                        capturedData = imageData
                        useCamera = false
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

                    if capturedData != nil {
                        Label("Photo captured (\(capturedData!.count) bytes)", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
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
                            Label("Seal", systemImage: "lock.shield")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(capturedData == nil && messageText.isEmpty)
                    }
                }

                Spacer()
            }
            .padding()
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
    
    private func sealContent() {
        let data = capturedData ?? Data(messageText.utf8)
        guard !data.isEmpty else { return }
        let burnEpoch = Int(Date().timeIntervalSince1970) + Int(burnHours * 3600)
        
        // Convert selected recipients to array (nil = everyone)
        let targets: [String]? = selectedRecipients.isEmpty ? nil : Array(selectedRecipients)
        
        coordinator.sealArtifact(data: data, burnAfter: burnEpoch, targetRecipients: targets)
        HapticEngine.handshakeHeartbeat()
        sealed = true
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
                        Text("Relay Server (optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("wss://relay.example.com", text: $coordinator.relayURL)
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
