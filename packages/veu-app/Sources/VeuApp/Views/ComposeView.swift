#if canImport(SwiftUI)
import SwiftUI
import VeuGlaze

/// Compose and seal a new artifact.
public struct ComposeView: View {
    let appState: AppState
    let onSealed: () -> Void
    @State private var messageText: String = ""
    @State private var burnHours: Double = 24
    @State private var isSealing = false
    @State private var sealed = false
    @Environment(\.dismiss) private var dismiss

    public init(appState: AppState, onSealed: @escaping () -> Void) {
        self.appState = appState
        self.onSealed = onSealed
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Compose Artifact")
                    .font(.title2)
                    .fontWeight(.semibold)

                // In a full app, this would be a camera capture.
                // For the POC, we use text input as the artifact payload.
                TextField("Enter message to encrypt…", text: $messageText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                VStack(alignment: .leading, spacing: 8) {
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
                    Button(action: seal) {
                        HStack {
                            Image(systemName: "lock.shield")
                            Text("Seal")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(messageText.isEmpty || isSealing)
                }

                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func seal() {
        guard !messageText.isEmpty else { return }
        isSealing = true
        let vm = TimelineViewModel(appState: appState)
        let burnEpoch = Int(Date().timeIntervalSince1970) + Int(burnHours * 3600)
        do {
            try vm.compose(
                data: Data(messageText.utf8),
                artifactType: "message",
                burnAfter: burnEpoch
            )
            HapticEngine.handshakeHeartbeat()
            sealed = true
            onSealed()
        } catch {
            // In production, show an error alert
        }
        isSealing = false
    }
}
#endif
