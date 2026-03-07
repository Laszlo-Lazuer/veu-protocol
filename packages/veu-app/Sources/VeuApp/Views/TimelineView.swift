#if canImport(SwiftUI)
import SwiftUI
import VeuGlaze

/// Displays the artifact timeline for the active circle with Glaze rendering.
public struct TimelineView: View {
    let appState: AppState
    @State private var vm: TimelineViewModel?
    @State private var showCompose = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationStack {
            Group {
                if appState.activeCircleID == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Active Circle")
                            .font(.headline)
                        Text("Complete a handshake to create a circle first.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else if let vm = vm, !vm.entries.isEmpty {
                    artifactGrid(entries: vm.entries)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Artifacts")
                            .font(.headline)
                        Text("Tap + to compose and seal your first artifact.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Timeline")
            .toolbar {
                if appState.activeCircleID != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showCompose = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showCompose) {
                ComposeView(appState: appState, onSealed: {
                    let model = TimelineViewModel(appState: appState)
                    try? model.reload()
                    vm = model
                })
            }
            .onAppear {
                let model = TimelineViewModel(appState: appState)
                try? model.reload()
                vm = model
            }
        }
    }

    private func artifactGrid(entries: [TimelineEntry]) -> some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 120, maximum: 180))
            ], spacing: 12) {
                ForEach(entries, id: \.cid) { entry in
                    AuraView(
                        seedColor: SIMD3<Float>(
                            entry.glazeSeedColor.r,
                            entry.glazeSeedColor.g,
                            entry.glazeSeedColor.b
                        ),
                        pulse: 0.0
                    )
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .vueToggle(
                        seedColor: SIMD3<Float>(
                            entry.glazeSeedColor.r,
                            entry.glazeSeedColor.g,
                            entry.glazeSeedColor.b
                        ),
                        onReveal: {
                            HapticEngine.vueHum()
                        },
                        onGlaze: {
                            HapticEngine.burnClick()
                        }
                    )
                }
            }
            .padding()
        }
    }
}
#endif
