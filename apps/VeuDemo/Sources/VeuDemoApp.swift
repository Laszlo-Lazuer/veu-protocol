import SwiftUI
import BackgroundTasks
import VeuApp

/// Veu Protocol — Two-Device POC Demo App.
///
/// Exercises the full demo flow on real hardware:
/// Identity → Dead Link QR → Handshake → Capture → Encrypt → Sync → Reveal.
@main
struct VeuDemoApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            if let state = coordinator.appState {
                DemoRootView(appState: state, coordinator: coordinator)
            } else {
                ProgressView("Bootstrapping identity…")
                    .task { coordinator.bootstrap() }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                coordinator.scheduleBackgroundSync()
            case .active:
                if coordinator.networkRunning {
                    coordinator.startNetwork()
                }
            default:
                break
            }
        }
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.veu.protocol.sync.refresh",
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            AppCoordinator.handleBackgroundRefresh(refreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.veu.protocol.sync.processing",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            AppCoordinator.handleBackgroundProcessing(processingTask)
        }
    }
}
