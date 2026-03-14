// VoiceFrameTransport.swift — Veu Protocol: Encrypted audio frame transport
//
// Encrypts outgoing audio frames with AES-256-GCM using the Circle Key
// and decrypts incoming frames. Each frame gets a unique nonce derived
// from the call ID + sequence number to prevent nonce reuse.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Encrypts and decrypts voice call audio frames.
///
/// Wire format per frame:
/// ```
/// [2-byte big-endian sequence][AES-256-GCM sealed box: nonce(12) || ciphertext || tag(16)]
/// ```
///
/// Nonce derivation: HKDF-SHA256(circleKey, info: callID + seq bytes) → 12 bytes
/// This ensures unique nonces without transmitting them separately.
public final class VoiceFrameTransport {
    private let circleKey: SymmetricKey
    private let callID: String
    private let callIDData: Data

    /// - Parameters:
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - callID: Unique identifier for this call/room session.
    public init(circleKey: Data, callID: String) {
        self.circleKey = SymmetricKey(data: circleKey)
        self.callID = callID
        self.callIDData = callID.data(using: .utf8) ?? Data()
    }

    /// Encrypt an audio frame for transmission.
    ///
    /// - Parameter frame: Raw frame data: `[2-byte seq][compressed audio]`
    /// - Returns: Encrypted frame: `[2-byte seq][AES-256-GCM sealed box]`
    public func encrypt(frame: Data) throws -> Data {
        guard frame.count >= 3 else {
            throw VoiceTransportError.frameTooShort
        }

        let seqBytes = frame.prefix(2)
        let audioData = frame.suffix(from: 2)

        // Derive unique nonce from callID + sequence
        let nonce = try deriveNonce(seqBytes: seqBytes)

        // Encrypt audio data
        let sealedBox = try AES.GCM.seal(audioData, using: circleKey, nonce: nonce)
        guard let combined = sealedBox.combined else {
            throw VoiceTransportError.encryptionFailed
        }

        // Output: [2-byte seq][sealed box (nonce + ciphertext + tag)]
        var encrypted = Data()
        encrypted.append(seqBytes)
        // Skip the nonce in the sealed box since we derive it — only send ciphertext + tag
        encrypted.append(sealedBox.ciphertext)
        encrypted.append(sealedBox.tag)
        return encrypted
    }

    /// Decrypt a received encrypted audio frame.
    ///
    /// - Parameter frame: Encrypted frame: `[2-byte seq][ciphertext || tag(16)]`
    /// - Returns: Decrypted frame: `[2-byte seq][compressed audio]`
    public func decrypt(frame: Data) throws -> Data {
        // Minimum: 2 (seq) + 1 (ciphertext) + 16 (tag) = 19 bytes
        guard frame.count >= 19 else {
            throw VoiceTransportError.frameTooShort
        }

        let seqBytes = frame.prefix(2)
        let encryptedPayload = frame.suffix(from: 2)

        // Derive the same nonce
        let nonce = try deriveNonce(seqBytes: seqBytes)

        // Split ciphertext and tag
        let tagStart = encryptedPayload.count - 16
        let ciphertext = encryptedPayload.prefix(tagStart)
        let tag = encryptedPayload.suffix(16)

        // Reconstruct sealed box with derived nonce
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )

        let decrypted = try AES.GCM.open(sealedBox, using: circleKey)

        var result = Data()
        result.append(seqBytes)
        result.append(decrypted)
        return result
    }

    // MARK: - Private

    /// Derive a 12-byte nonce from callID + sequence number using HKDF.
    private func deriveNonce(seqBytes: Data) throws -> AES.GCM.Nonce {
        var info = callIDData
        info.append(seqBytes)

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: circleKey,
            info: info,
            outputByteCount: 12
        )

        return try AES.GCM.Nonce(data: derived.withUnsafeBytes { Data($0) })
    }
}

/// Errors from voice frame transport.
public enum VoiceTransportError: Error, LocalizedError {
    case frameTooShort
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .frameTooShort: return "Audio frame too short"
        case .encryptionFailed: return "Failed to encrypt audio frame"
        case .decryptionFailed: return "Failed to decrypt audio frame"
        }
    }
}
