// VeuGhostError.swift — Veu Protocol: Ghost Network Error Types

import Foundation

/// Errors produced by the `VeuGhost` module.
public enum VeuGhostError: Error, Equatable {
    /// mDNS/Bonjour service discovery failed.
    case discoveryFailed(String)

    /// A peer connection could not be established or was lost.
    case connectionFailed(String)

    /// The sync protocol encountered an error (delta exchange, merge).
    case syncFailed(String)

    /// AES-256-GCM encryption or decryption of a Ghost message failed.
    case encryptionFailed(String)

    /// A received message could not be decoded (invalid JSON or envelope).
    case decodingFailed(String)

    /// A network operation timed out.
    case timeout

    // MARK: - Equatable

    public static func == (lhs: VeuGhostError, rhs: VeuGhostError) -> Bool {
        switch (lhs, rhs) {
        case (.timeout, .timeout):
            return true
        case (.discoveryFailed(let a), .discoveryFailed(let b)),
             (.connectionFailed(let a), .connectionFailed(let b)),
             (.syncFailed(let a), .syncFailed(let b)),
             (.encryptionFailed(let a), .encryptionFailed(let b)),
             (.decodingFailed(let a), .decodingFailed(let b)):
            return a == b
        default:
            return false
        }
    }
}
