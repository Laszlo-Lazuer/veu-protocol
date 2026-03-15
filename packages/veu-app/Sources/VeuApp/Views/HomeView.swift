#if canImport(SwiftUI)
import SwiftUI
import VeuGlaze
import VeuAuth

/// Root view for the Veu POC app — tab-based navigation.
public struct HomeView: View {
    let appState: AppState
    @StateObject private var voiceCallManager = VoiceCallManager()

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ZStack {
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

            #if os(iOS)
            // Full-screen call overlay when a call is active
            if voiceCallManager.state != .idle,
               case .ended = voiceCallManager.state {
                // Don't show overlay for brief ended state
            } else if voiceCallManager.state != .idle {
                ActiveCallView(callManager: voiceCallManager)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
            #endif
        }
        .onAppear { wireVoiceCallManager() }
    }

    private func wireVoiceCallManager() {
        voiceCallManager.deviceID = appState.identity.deviceID
        voiceCallManager.callsign = appState.identity.callsign
        if let circleID = appState.activeCircleID {
            voiceCallManager.circleID = circleID
            voiceCallManager.circleKey = appState.circleKeys[circleID]?.keyData
        }
        voiceCallManager.signingKey = try? appState.identity.signingPrivateKey
    }
}
#endif
