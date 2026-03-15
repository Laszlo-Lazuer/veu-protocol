#if canImport(SwiftUI)
import SwiftUI
import VeuGlaze
import VeuAuth

/// Root view for the Veu POC app — tab-based navigation.
public struct HomeView: View {
    let appState: AppState
    @StateObject private var voiceCallManager = VoiceCallManager()

    #if os(iOS)
    @StateObject private var pushKitManager = PushKitManager()
    #endif

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

        #if os(iOS)
        // Pass VoIP push token to voice call manager for relay registration
        voiceCallManager.pushToken = pushKitManager.pushToken

        // Wire PushKit incoming push → CallKit incoming call
        pushKitManager.onIncomingPush = { [weak voiceCallManager] callID, callerName, payload in
            guard let manager = voiceCallManager else { return }
            let callerDeviceID = payload["caller_device_id"] as? String ?? "unknown"
            let circleID = payload["circle_id"] as? String ?? ""

            // Report to CallKit first (required by PushKit before returning)
            manager.callKitManager.reportIncomingCall(
                callID: callID,
                callerName: callerName
            ) { error in
                if let error = error {
                    print("[HomeView] ❌ Failed to report incoming call: \(error)")
                    return
                }
                // Build a VoiceCallPayload to trigger standard incoming call flow
                let voicePayload = GhostMessage.VoiceCallPayload(
                    callID: callID,
                    action: .offer,
                    senderDeviceID: callerDeviceID,
                    senderCallsign: callerName,
                    recipientDeviceID: manager.deviceID
                )
                DispatchQueue.main.async {
                    manager.handleIncomingOffer(voicePayload)
                }
            }
        }
        #endif
    }
}
#endif
