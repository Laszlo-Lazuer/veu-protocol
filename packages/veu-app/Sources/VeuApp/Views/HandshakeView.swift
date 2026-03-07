#if canImport(SwiftUI)
import SwiftUI
import VeuGlaze
import VeuAuth

/// Drives the Emerald Handshake UI: initiate/respond → verify short code → confirm.
public struct HandshakeView: View {
    let appState: AppState
    @State private var vm: HandshakeViewModel?
    @State private var scannedURI: String = ""
    @State private var showResponder = false

    public init(appState: AppState) {
        self.appState = appState
    }

    private var viewModel: HandshakeViewModel {
        if let vm = vm { return vm }
        let newVM = HandshakeViewModel(appState: appState)
        DispatchQueue.main.async { self.vm = newVM }
        return newVM
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Phase indicator
                EmeraldView(
                    phase: vm?.phase ?? .idle,
                    progress: phaseProgress
                )
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                phaseContent

                Spacer()
            }
            .padding()
            .navigationTitle("Emerald Handshake")
        }
    }

    private var phaseProgress: Float {
        switch vm?.phase ?? .idle {
        case .idle: return 0
        case .initiating: return 0.25
        case .awaiting: return 0.5
        case .verifying: return 0.75
        case .confirmed: return 1.0
        case .deadLink, .ghost: return 0
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch vm?.phase ?? .idle {
        case .idle:
            VStack(spacing: 16) {
                Button("Create Circle (Initiator)") {
                    let model = HandshakeViewModel(appState: appState)
                    vm = model
                    try? model.initiate()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Join Circle (Responder)") {
                    showResponder = true
                }
                .buttonStyle(.bordered)
                .sheet(isPresented: $showResponder) {
                    responderSheet
                }
            }

        case .initiating:
            VStack(spacing: 12) {
                if let uri = vm?.deadLinkURI {
                    Text("Share this Dead Link:")
                        .font(.headline)
                    Text(uri)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
                Text("Waiting for peer response…")
                    .foregroundColor(.secondary)
            }

        case .verifying:
            VStack(spacing: 16) {
                Text("Verify Short Code")
                    .font(.headline)
                if let code = vm?.shortCode {
                    Text(code)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .kerning(4)
                }
                if let color = vm?.auraColorHex {
                    Circle()
                        .fill(Color(hex: color))
                        .frame(width: 60, height: 60)
                }
                HStack(spacing: 20) {
                    Button("Reject") {
                        vm?.reject()
                        HapticEngine.burnClick()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button("Confirm") {
                        try? vm?.confirm()
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
                Text("Circle ID: \(vm?.circleID ?? "—")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("New Handshake") {
                    vm?.reset()
                }
                .buttonStyle(.bordered)
            }

        case .awaiting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Computing shared secret…")
                    .foregroundColor(.secondary)
            }

        case .deadLink:
            errorView(message: "Dead Link expired", icon: "link.badge.plus")

        case .ghost:
            errorView(message: vm?.errorMessage ?? "Handshake failed", icon: "xmark.octagon")
        }
    }

    private var responderSheet: some View {
        VStack(spacing: 16) {
            Text("Enter Dead Link URI")
                .font(.headline)
            TextField("veu://handshake?…", text: $scannedURI)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
            Button("Connect") {
                let model = HandshakeViewModel(appState: appState)
                vm = model
                _ = try? model.respond(to: scannedURI)
                showResponder = false
            }
            .buttonStyle(.borderedProminent)
            .disabled(scannedURI.isEmpty)
        }
        .padding()
    }

    private func errorView(message: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text(message)
                .foregroundColor(.secondary)
            Button("Try Again") {
                vm?.reset()
            }
            .buttonStyle(.bordered)
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
#endif
