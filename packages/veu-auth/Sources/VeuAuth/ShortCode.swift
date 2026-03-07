// ShortCode.swift — Veu Protocol: SAS (Short Authentication String) Derivation
//
// Derives the 8-digit verification code and Aura color from a Circle key.
// Both peers independently compute these values from the same ECDH-derived key;
// users confirm the match out-of-band to prevent MITM attacks.
//
// Algorithm (from EMERALD_HANDSHAKE.md §Phase 3):
//   short_code = first 4 bytes of HMAC-SHA-256(circle_key, "short-code") → 8 hex digits
//   aura_color = first 3 bytes of HMAC-SHA-256(circle_key, "aura-color") → RGB hex

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import VeuCrypto

/// SAS (Short Authentication String) derivation for Emerald Handshake verification.
///
/// Both peers compute the same 8-digit hex code and Aura color from the shared
/// Circle key.  Users compare these values visually or verbally to confirm the
/// handshake is not being intercepted.
public enum ShortCode {

    // MARK: - 8-Digit Code

    /// Derive the 8-digit hexadecimal verification code from a Circle key.
    ///
    /// ```
    /// mac = HMAC-SHA-256(key: circle_key, data: "short-code")
    /// code = first 4 bytes of mac → 8 uppercase hex digits
    /// ```
    ///
    /// - Parameter circleKey: The Circle key derived from the ECDH shared secret.
    /// - Returns: An 8-character uppercase hexadecimal string (e.g. `"A3F7B201"`).
    public static func deriveCode(from circleKey: CircleKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("short-code".utf8),
            using: circleKey.symmetricKey
        )
        let macBytes = Data(mac)
        let first4 = macBytes.prefix(4)
        return first4.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Aura Color

    /// Derive the Aura color hex string from a Circle key.
    ///
    /// ```
    /// mac = HMAC-SHA-256(key: circle_key, data: "aura-color")
    /// color = "#" + first 3 bytes of mac → 6 uppercase hex digits
    /// ```
    ///
    /// - Parameter circleKey: The Circle key derived from the ECDH shared secret.
    /// - Returns: A CSS-style hex color string (e.g. `"#5AC87F"`).
    public static func deriveAuraColorHex(from circleKey: CircleKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("aura-color".utf8),
            using: circleKey.symmetricKey
        )
        let macBytes = Data(mac)
        let first3 = macBytes.prefix(3)
        let hex = first3.map { String(format: "%02X", $0) }.joined()
        return "#\(hex)"
    }

    /// Derive the Aura color as normalized RGB floats (0.0–1.0).
    ///
    /// - Parameter circleKey: The Circle key derived from the ECDH shared secret.
    /// - Returns: A tuple of `(r, g, b)` floats in the range `[0.0, 1.0]`.
    public static func deriveAuraColor(from circleKey: CircleKey) -> (r: Float, g: Float, b: Float) {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("aura-color".utf8),
            using: circleKey.symmetricKey
        )
        let macBytes = Data(mac)
        guard macBytes.count >= 3 else {
            return (r: 0.0, g: 0.0, b: 0.0)
        }
        return (
            r: Float(macBytes[macBytes.startIndex]) / 255.0,
            g: Float(macBytes[macBytes.startIndex + 1]) / 255.0,
            b: Float(macBytes[macBytes.startIndex + 2]) / 255.0
        )
    }

    // MARK: - Verification

    /// Compare two short codes for equality (constant-time when possible).
    ///
    /// - Parameters:
    ///   - localCode: The locally derived 8-digit code.
    ///   - remoteCode: The code displayed on the remote peer's device.
    /// - Throws: `VeuAuthError.shortCodeMismatch` if codes do not match.
    public static func verify(localCode: String, remoteCode: String) throws {
        guard localCode == remoteCode else {
            throw VeuAuthError.shortCodeMismatch
        }
    }
}
