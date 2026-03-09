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

            DemoTimelineTab(appState: appState, coordinator: coordinator)
                .tabItem {
                    Label("Timeline", systemImage: "photo.on.rectangle.angled")
                }
                .tag(2)

            NetworkTab(coordinator: coordinator)
                .tabItem {
                    Label("Network", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(3)
        }
        .tint(.green)
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
    @State private var showScanner = false
    @State private var showInitiator = false

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
            .onChange(of: coordinator.handshakePhase) { _ in
                if coordinator.handshakePhase != .initiating {
                    showInitiator = false
                }
            }
        }
    }

    @ViewBuilder
    private var handshakeContent: some View {
        switch coordinator.handshakePhase {
        case .idle:
            VStack(spacing: 16) {
                Button {
                    showInitiator = true
                    coordinator.initiateHandshake()
                } label: {
                    Label("Create Circle", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    showScanner = true
                } label: {
                    Label("Scan to Join", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .sheet(isPresented: $showInitiator) {
                InitiatorSheet(coordinator: coordinator)
            }
            .sheet(isPresented: $showScanner) {
                ScannerSheet(coordinator: coordinator, isPresented: $showScanner)
            }

        case .initiating:
            InitiatorSheet(coordinator: coordinator)

        case .awaiting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Computing shared secret…")
                    .foregroundColor(.secondary)
            }

        case .verifying:
            VStack(spacing: 16) {
                // Responder: show response QR for the initiator to scan
                if let responseURI = coordinator.responsePayload {
                    VStack(spacing: 8) {
                        Text("Show this to the initiator")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        QRCodeView(content: responseURI)
                            .frame(width: 150, height: 150)
                    }
                    .padding(.bottom, 4)
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

// MARK: - Initiator Sheet (QR display)

struct InitiatorSheet: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var showResponseScanner = false
    @State private var manualResponseURI = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Share this QR Code")
                    .font(.headline)

                if let uri = coordinator.deadLinkURI {
                    QRCodeView(content: uri)
                        .frame(width: 200, height: 200)

                    Text("Dead Link URI:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(uri)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }

                Divider()

                Text("After peer scans, scan their response QR:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if showResponseScanner {
                    QRScannerView { scannedURI in
                        coordinator.receiveResponse(uri: scannedURI)
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    Button {
                        showResponseScanner = true
                    } label: {
                        Label("Scan Response QR", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Text("— or enter manually —")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("veu://response?pk=…", text: $manualResponseURI)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Submit Response") {
                    coordinator.receiveResponse(uri: manualResponseURI)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(manualResponseURI.isEmpty)
            }
            .padding()
        }
    }
}

// MARK: - Scanner Sheet

struct ScannerSheet: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var isPresented: Bool
    @State private var manualURI = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Camera-based QR scanner
                QRScannerView { scannedURI in
                    coordinator.respondToHandshake(uri: scannedURI)
                    isPresented = false
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text("— or enter manually —")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("veu://handshake?…", text: $manualURI)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Connect") {
                    coordinator.respondToHandshake(uri: manualURI)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualURI.isEmpty)
            }
            .padding()
            .navigationTitle("Scan Dead Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
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
            Group {
                if appState.activeCircleID == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Active Circle")
                            .font(.headline)
                        Text("Complete a handshake first.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else if coordinator.timelineEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Artifacts")
                            .font(.headline)
                        Text("Capture a photo or type a message to seal.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 120, maximum: 180))
                        ], spacing: 12) {
                            ForEach(coordinator.timelineEntries, id: \.cid) { entry in
                                ZStack {
                                    // Revealed content shown after biometric auth
                                    if let data = entry.plaintextData,
                                       let uiImage = UIImage(data: data) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                    } else if let data = entry.plaintextData,
                                              let text = String(data: data, encoding: .utf8) {
                                        Text(text)
                                            .font(.caption)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(Color(.systemBackground))
                                    } else {
                                        Color.gray.opacity(0.2)
                                    }
                                }
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .vueToggle(
                                    seedColor: SIMD3<Float>(
                                        entry.glazeSeedColor.r,
                                        entry.glazeSeedColor.g,
                                        entry.glazeSeedColor.b
                                    ),
                                    onReveal: { HapticEngine.vueHum() },
                                    onGlaze: { HapticEngine.burnClick() }
                                )
                            }
                        }
                        .padding()
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
                            let data = capturedData ?? Data(messageText.utf8)
                            guard !data.isEmpty else { return }
                            let burnEpoch = Int(Date().timeIntervalSince1970) + Int(burnHours * 3600)
                            coordinator.sealArtifact(data: data, burnAfter: burnEpoch)
                            HapticEngine.handshakeHeartbeat()
                            sealed = true
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
        }
    }
}

// MARK: - Network Tab

struct NetworkTab: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Status indicator
                HStack {
                    Circle()
                        .fill(coordinator.networkRunning ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(coordinator.networkRunning ? "Ghost Network Active" : "Ghost Network Offline")
                        .font(.headline)
                }

                if coordinator.networkRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoRow(label: "Device ID", value: coordinator.appState?.identity.deviceID ?? "—")
                        InfoRow(label: "Active Circle", value: coordinator.appState?.activeCircleID.map { String($0.prefix(8)) + "…" } ?? "None")
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
                    Button {
                        coordinator.startNetwork()
                    } label: {
                        Label("Start Ghost Network", systemImage: "antenna.radiowaves.left.and.right")
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
            .navigationTitle("Ghost Network")
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
