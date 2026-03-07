#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Glaze Seed derivation — turns an encrypted artifact into a deterministic art seed.
///
/// The seed is computed as: `HMAC-SHA256(key: salt, data: ciphertext)`
public enum GlazeSeed {
    /// Derive a 32-byte (256-bit) Glaze Seed from ciphertext and a Circle's glaze salt.
    ///
    /// - Parameters:
    ///   - ciphertext: The raw encrypted bytes of the artifact (from `VeuArtifact.ciphertext`).
    ///   - salt:       The Circle's `glaze_salt` (128-bit / 16-byte shared secret).
    /// - Returns: 32 bytes of deterministic seed material.
    public static func glazeSeed(from ciphertext: Data, salt: Data) -> Data {
        let key  = SymmetricKey(data: salt)
        let hmac = HMAC<SHA256>.authenticationCode(for: ciphertext, using: key)
        return Data(hmac)
    }

    /// Derive a deterministic RGB color from the first three bytes of a Glaze Seed.
    ///
    /// Each channel is normalised to the range `[0.0, 1.0]`.
    /// The resulting triple feeds the `u_seed_color` uniform in the Veu GLSL shaders.
    ///
    /// - Parameter seed: A Glaze Seed (minimum 3 bytes; typically 32 bytes).
    /// - Returns: `(r, g, b)` floats in `[0, 1]`, or `(0, 0, 0)` if the seed is too short.
    public static func glazeColor(from seed: Data) -> (r: Float, g: Float, b: Float) {
        guard seed.count >= 3 else { return (0, 0, 0) }
        let r = Float(seed[seed.startIndex])     / 255.0
        let g = Float(seed[seed.startIndex + 1]) / 255.0
        let b = Float(seed[seed.startIndex + 2]) / 255.0
        return (r, g, b)
    }
}
