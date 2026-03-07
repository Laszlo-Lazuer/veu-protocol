// HapticEngine.swift — Veu Protocol: Cryptographic Haptic Feedback
//
// "Heavy Haptics" that simulate the weight of cryptographic operations.
// Three distinct patterns reinforce key protocol events with physical feedback.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Haptic feedback patterns for Veu protocol events.
///
/// Veu uses "Heavy Haptics" to make cryptographic operations feel physical:
/// - **Handshake Heartbeat**: rhythmic light+medium pulses during the Emerald Handshake
/// - **Burn Click**: sharp, heavy impact when an artifact is cryptographically destroyed
/// - **Vue Hum**: subtle continuous feedback while viewing a decrypted artifact
public enum HapticEngine {

    /// Trigger a "heartbeat" haptic during the Emerald Handshake ceremony.
    ///
    /// Pattern: light tap → 0.3s pause → medium tap.
    /// Designed to be called repeatedly during the VERIFYING phase.
    public static func handshakeHeartbeat() {
        #if os(iOS)
        let light = UIImpactFeedbackGenerator(style: .light)
        let medium = UIImpactFeedbackGenerator(style: .medium)
        light.prepare()
        medium.prepare()

        light.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            medium.impactOccurred()
        }
        #elseif os(macOS)
        performMacHaptic(pattern: .alignment)
        #endif
    }

    /// Trigger a "burn click" haptic when an artifact is cryptographically destroyed.
    ///
    /// Pattern: single heavy, sharp impact conveying finality.
    public static func burnClick() {
        #if os(iOS)
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        heavy.prepare()
        heavy.impactOccurred()
        #elseif os(macOS)
        performMacHaptic(pattern: .generic)
        #endif
    }

    /// Trigger a "vue hum" haptic while viewing a decrypted artifact.
    ///
    /// Pattern: subtle selection feedback.  Call once when the reveal begins;
    /// the app layer should repeat at intervals for a continuous hum.
    public static func vueHum() {
        #if os(iOS)
        let selection = UISelectionFeedbackGenerator()
        selection.prepare()
        selection.selectionChanged()
        #elseif os(macOS)
        performMacHaptic(pattern: .levelChange)
        #endif
    }

    // MARK: - macOS Haptic Helper

    #if os(macOS)
    private static func performMacHaptic(pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
    #endif
}
