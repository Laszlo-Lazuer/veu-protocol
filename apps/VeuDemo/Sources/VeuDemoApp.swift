import SwiftUI
import BackgroundTasks
import VeuApp
import UIKit

// MARK: - AppDelegate (Background Push + APNs Token)

final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var coordinator: AppCoordinator?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register for standard APNs (content-available background push)
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[AppDelegate] APNs device token: \(hex.prefix(16))…")
        coordinator?.registerAPNsToken(hex)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] APNs registration failed: \(error)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        coordinator?.handleBackgroundPush(userInfo: userInfo, completion: completionHandler)
    }
}

// MARK: - App Entry Point

/// Veu Protocol — Two-Device POC Demo App.
///
/// Exercises the full demo flow on real hardware:
/// Identity → Dead Link QR → Handshake → Capture → Encrypt → Sync → Reveal.
@main
struct VeuDemoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var coordinator = AppCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            if let state = coordinator.appState {
                DemoRootView(appState: state, coordinator: coordinator)
                    .onAppear {
                        // Wire AppDelegate → coordinator for push callbacks
                        appDelegate.coordinator = coordinator
                    }
            } else {
                ProgressView("Bootstrapping identity…")
                    .task { coordinator.bootstrap() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                coordinator.handleBackgroundTransition()
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
