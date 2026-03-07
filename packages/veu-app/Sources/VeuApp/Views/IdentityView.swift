#if canImport(SwiftUI)
import SwiftUI
import VeuGlaze

/// Displays the device identity: Aura shader + callsign + device ID.
public struct IdentityView: View {
    let identity: Identity

    public init(identity: Identity) {
        self.identity = identity
    }

    public var body: some View {
        VStack(spacing: 24) {
            Text("Your Identity")
                .font(.title2)
                .fontWeight(.semibold)

            AuraView(
                seedColor: SIMD3<Float>(
                    identity.auraSeedR,
                    identity.auraSeedG,
                    identity.auraSeedB
                ),
                pulse: 0.0
            )
            .frame(width: 200, height: 200)
            .clipShape(Circle())

            VStack(spacing: 8) {
                Text(identity.callsign)
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.bold)

                Text("Device: \(identity.deviceID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}
#endif
