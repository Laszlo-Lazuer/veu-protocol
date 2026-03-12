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
/// When `sessionUnlocked` is true (and not in vault mode), content auto-reveals
/// without requiring per-item biometric authentication.
///
/// ```swift
/// Image(decryptedPhoto)
///     .vueToggle(glazeSeed: seed, sessionUnlocked: true, onReveal: { HapticEngine.vueHum() })
/// ```
public struct VueToggleModifier: ViewModifier {

    /// Glaze Seed color for the Aura overlay (RGB, `[0, 1]`).
    public var seedColor: SIMD3<Float>
    
    /// Whether the session is unlocked (FaceID done once at app launch).
    public var sessionUnlocked: Bool
    
    /// Whether this item is in vault mode (requires tap-to-reveal even when session is unlocked).
    public var isVaultMode: Bool
    
    /// Whether this content can be revealed by the current user (false for non-recipient targeted posts).
    public var canReveal: Bool

    /// Callback fired when the artifact is revealed (e.g., trigger haptic).
    public var onReveal: (() -> Void)?

    /// Callback fired when the artifact is re-glazed.
    public var onGlaze: (() -> Void)?

    @State private var isRevealed = false
    @State private var auraOpacity: Double = 1.0

    public init(
        seedColor: SIMD3<Float>,
        sessionUnlocked: Bool = false,
        isVaultMode: Bool = false,
        canReveal: Bool = true,
        onReveal: (() -> Void)? = nil,
        onGlaze: (() -> Void)? = nil
    ) {
        self.seedColor = seedColor
        self.sessionUnlocked = sessionUnlocked
        self.isVaultMode = isVaultMode
        self.canReveal = canReveal
        self.onReveal = onReveal
        self.onGlaze = onGlaze
    }

    public func body(content: Content) -> some View {
        let shouldAutoReveal = sessionUnlocked && !isVaultMode && canReveal
        
        ZStack {
            content

            #if canImport(MetalKit)
            AuraView(seedColor: seedColor, pulse: 0.0)
                .opacity(shouldAutoReveal ? 0.0 : auraOpacity)
                .allowsHitTesting(false)
            #endif
        }
        .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
            guard !shouldAutoReveal else { return }  // Already revealed
            guard canReveal else { return }  // Can't reveal (not a recipient)
            if pressing {
                authenticate()
            } else {
                reglaze()
            }
        }, perform: {})
        .onAppear {
            if shouldAutoReveal {
                auraOpacity = 0.0
                isRevealed = true
            }
        }
        .onChange(of: sessionUnlocked) { newValue in
            if newValue && !isVaultMode && canReveal {
                withAnimation(.easeInOut(duration: 0.2)) {
                    auraOpacity = 0.0
                    isRevealed = true
                }
                onReveal?()
            } else if !newValue {
                withAnimation(.easeInOut(duration: 0.2)) {
                    auraOpacity = 1.0
                    isRevealed = false
                }
                onGlaze?()
            }
        }
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
    ///   - sessionUnlocked: Whether the session is unlocked (auto-reveal without per-item auth).
    ///   - isVaultMode: Whether this item requires tap-to-reveal even when session is unlocked.
    ///   - canReveal: Whether the current user can reveal this content (false for non-recipient targeted posts).
    ///   - onReveal: Callback when the artifact is revealed.
    ///   - onGlaze: Callback when the artifact is re-glazed.
    func vueToggle(
        seedColor: SIMD3<Float>,
        sessionUnlocked: Bool = false,
        isVaultMode: Bool = false,
        canReveal: Bool = true,
        onReveal: (() -> Void)? = nil,
        onGlaze: (() -> Void)? = nil
    ) -> some View {
        modifier(VueToggleModifier(
            seedColor: seedColor,
            sessionUnlocked: sessionUnlocked,
            isVaultMode: isVaultMode,
            canReveal: canReveal,
            onReveal: onReveal,
            onGlaze: onGlaze
        ))
    }
}
#endif
