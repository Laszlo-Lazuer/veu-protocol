#if canImport(SwiftUI)
import SwiftUI
import VeuGlaze
import VeuAuth

/// Root view for the Veu POC app — tab-based navigation.
public struct HomeView: View {
    let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        TabView {
            IdentityView(identity: appState.identity)
                .tabItem {
                    Label("Identity", systemImage: "person.circle")
                }

            HandshakeView(appState: appState)
                .tabItem {
                    Label("Handshake", systemImage: "hand.wave")
                }

            TimelineView(appState: appState)
                .tabItem {
                    Label("Timeline", systemImage: "photo.on.rectangle")
                }
        }
    }
}
#endif
