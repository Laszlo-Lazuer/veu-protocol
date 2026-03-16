#if canImport(SwiftUI)
import SwiftUI

/// Veu Protocol POC Demo App entry point.
///
/// Wires together all four packages (veu-crypto, veu-auth, veu-glaze, veu-ghost)
/// into a minimal SwiftUI app demonstrating the full demo flow:
/// Identity → Handshake → Compose → Sync → Reveal.
///
/// Usage in an Xcode project:
/// ```swift
/// import SwiftUI
/// import VeuApp
///
/// @main
/// struct MyApp: App {
///     @State private var appState: AppState? = nil
///     var body: some Scene {
///         WindowGroup {
///             if let state = appState {
///                 HomeView(appState: state)
///             } else {
///                 ProgressView("Bootstrapping…")
///                     .onAppear { appState = try? AppState.bootstrap() }
///             }
///         }
///     }
/// }
/// ```
public enum VeuAppKit {
    /// Library version.
    public static let version = "1.1.0"

    /// Create a bootstrapped AppState with a fresh identity and in-memory ledger.
    public static func bootstrap() throws -> AppState {
        try AppState.bootstrap()
    }
}
#else
// Non-SwiftUI platforms: library-only.
public enum VeuAppKit {
    public static let version = "1.1.0"

    public static func bootstrap() throws -> AppState {
        try AppState.bootstrap()
    }
}
#endif
