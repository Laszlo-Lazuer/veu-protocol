#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// Full-screen active call view — shows during outgoing ring, incoming ring, and active call.
public struct ActiveCallView: View {
    @ObservedObject var callManager: VoiceCallManager

    public init(callManager: VoiceCallManager) {
        self.callManager = callManager
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Peer identity
                peerInfoSection

                // Call status
                statusLabel

                // Duration (active calls only)
                if case .active = callManager.state {
                    Text(formattedDuration)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))

                    transportBadge
                }

                Spacer()

                // Action buttons
                actionButtons

                Spacer().frame(height: 40)
            }
            .padding()
        }
    }

    // MARK: - Peer Info

    @ViewBuilder
    private var peerInfoSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.white.opacity(0.6))

            Text(peerName)
                .font(.title)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Text(peerDeviceID)
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Status Label

    @ViewBuilder
    private var statusLabel: some View {
        switch callManager.state {
        case .outgoingRinging:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("Ringing…")
                    .foregroundColor(.white.opacity(0.7))
            }
        case .incomingRinging:
            Text("Incoming Call")
                .font(.headline)
                .foregroundColor(.green)
        case .active:
            Text("Connected")
                .font(.subheadline)
                .foregroundColor(.green.opacity(0.8))
        case .ended(let reason):
            Text(reason)
                .font(.subheadline)
                .foregroundColor(.red.opacity(0.8))
        default:
            EmptyView()
        }
    }

    // MARK: - Transport Badge

    @ViewBuilder
    private var transportBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: transportIcon)
                .font(.caption2)
            Text(transportLabel)
                .font(.caption2)
        }
        .foregroundColor(.white.opacity(0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch callManager.state {
        case .incomingRinging:
            HStack(spacing: 60) {
                // Decline
                CallButton(
                    icon: "phone.down.fill",
                    color: .red,
                    label: "Decline"
                ) {
                    callManager.declineCall()
                }

                // Accept
                CallButton(
                    icon: "phone.fill",
                    color: .green,
                    label: "Accept"
                ) {
                    callManager.acceptCall()
                }
            }

        case .outgoingRinging, .active:
            HStack(spacing: 40) {
                // Mute
                CallButton(
                    icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                    color: callManager.isMuted ? .red : .white.opacity(0.3),
                    label: callManager.isMuted ? "Unmute" : "Mute"
                ) {
                    callManager.isMuted.toggle()
                }

                // End Call
                CallButton(
                    icon: "phone.down.fill",
                    color: .red,
                    label: "End",
                    size: 70
                ) {
                    callManager.endCall()
                }

                // Speaker
                CallButton(
                    icon: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                    color: callManager.isSpeakerOn ? .blue : .white.opacity(0.3),
                    label: "Speaker"
                ) {
                    callManager.isSpeakerOn.toggle()
                }
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Computed Properties

    private var peerName: String {
        switch callManager.state {
        case .outgoingRinging(_, let peer): return peer.prefix(8).description
        case .incomingRinging(_, _, let callsign): return callsign
        case .active(_, _, let callsign): return callsign
        default: return ""
        }
    }

    private var peerDeviceID: String {
        switch callManager.state {
        case .outgoingRinging(_, let peer): return peer
        case .incomingRinging(_, let device, _): return device
        case .active(_, let device, _): return device
        default: return ""
        }
    }

    private var formattedDuration: String {
        let total = Int(callManager.callDuration)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var transportIcon: String {
        #if os(iOS)
        if callManager.peerUDPConnected { return "antenna.radiowaves.left.and.right" }
        if callManager.usingRelay { return "cloud.fill" }
        return "network"
        #else
        return "network"
        #endif
    }

    private var transportLabel: String {
        #if os(iOS)
        if callManager.peerUDPConnected { return "Direct (UDP)" }
        if callManager.usingRelay { return "Relay" }
        return "Mesh"
        #else
        return "Mesh"
        #endif
    }
}

// MARK: - Call Button

private struct CallButton: View {
    let icon: String
    let color: Color
    let label: String
    var size: CGFloat = 56
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.4))
                    .foregroundColor(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(color))
            }
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
    }
}
#endif
