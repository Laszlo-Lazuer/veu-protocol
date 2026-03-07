import SwiftUI
import VeuApp

/// Veu Protocol — Two-Device POC Demo App.
///
/// Exercises the full demo flow on real hardware:
/// Identity → Dead Link QR → Handshake → Capture → Encrypt → Sync → Reveal.
@main
struct VeuDemoApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            if let state = coordinator.appState {
                DemoRootView(appState: state, coordinator: coordinator)
            } else {
                ProgressView("Bootstrapping identity…")
                    .task { coordinator.bootstrap() }
            }
        }
    }
}
