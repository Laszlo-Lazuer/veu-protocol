// VueToggle.swift — Veu Protocol: Long-Press → Biometric → Reveal Toggle
//
// The Vue Toggle is the core interaction of the Veu app: a long-press gesture
// triggers biometric authentication, and on success the shader overlay fades
// to reveal the decrypted artifact underneath.

#if canImport(SwiftUI) && canImport(LocalAuthentication)
import SwiftUI
import LocalAuthentication

/// A view modifier that wraps content in the "Vue Toggle" interaction.
///
/// In the **Glazed** state, the Aura shader covers the content.
/// A long-press triggers biometric auth (FaceID / TouchID); on success
/// the shader fades out, revealing the decrypted artifact.  Releasing the
/// long-press re-glazes the content.
///
/// ```swift
/// Image(decryptedPhoto)
///     .vueToggle(glazeSeed: seed, onReveal: { HapticEngine.vueHum() })
/// ```
public struct VueToggleModifier: ViewModifier {

    /// Glaze Seed color for the Aura overlay (RGB, `[0, 1]`).
    public var seedColor: SIMD3<Float>

    /// Callback fired when the artifact is revealed (e.g., trigger haptic).
    public var onReveal: (() -> Void)?

    /// Callback fired when the artifact is re-glazed.
    public var onGlaze: (() -> Void)?

    @State private var isRevealed = false
    @State private var auraOpacity: Double = 1.0

    public init(seedColor: SIMD3<Float>,
                onReveal: (() -> Void)? = nil,
                onGlaze: (() -> Void)? = nil) {
        self.seedColor = seedColor
        self.onReveal = onReveal
        self.onGlaze = onGlaze
    }

    public func body(content: Content) -> some View {
        ZStack {
            content

            #if canImport(MetalKit)
            AuraView(seedColor: seedColor, pulse: 0.0)
                .opacity(auraOpacity)
                .allowsHitTesting(false)
            #endif
        }
        .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
            if pressing {
                authenticate()
            } else {
                reglaze()
            }
        }, perform: {})
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Authenticate to reveal artifact"
        ) { success, _ in
            DispatchQueue.main.async {
                if success {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        auraOpacity = 0.0
                        isRevealed = true
                    }
                    onReveal?()
                }
            }
        }
    }

    private func reglaze() {
        guard isRevealed else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            auraOpacity = 1.0
            isRevealed = false
        }
        onGlaze?()
    }
}

// MARK: - View Extension

public extension View {
    /// Apply the Vue Toggle interaction: long-press → biometric → reveal.
    ///
    /// - Parameters:
    ///   - seedColor: RGB seed color for the Aura overlay.
    ///   - onReveal: Callback when the artifact is revealed.
    ///   - onGlaze: Callback when the artifact is re-glazed.
    func vueToggle(
        seedColor: SIMD3<Float>,
        onReveal: (() -> Void)? = nil,
        onGlaze: (() -> Void)? = nil
    ) -> some View {
        modifier(VueToggleModifier(seedColor: seedColor, onReveal: onReveal, onGlaze: onGlaze))
    }
}
#endif
