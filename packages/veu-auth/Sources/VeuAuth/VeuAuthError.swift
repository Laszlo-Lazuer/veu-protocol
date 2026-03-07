// VeuAuthError.swift — Veu Protocol: Authentication Error Types
//
// Domain-specific errors for the veu-auth package covering handshake,
// Dead Link, ledger, and SAS verification failures.

import Foundation

/// Errors produced by the `VeuAuth` module.
public enum VeuAuthError: Error, Equatable {
    /// The Dead Link URI has expired (TTL elapsed).
    case deadLinkExpired

    /// The Dead Link URI could not be parsed or is structurally invalid.
    case deadLinkInvalid

    /// The Ed25519 signature on a Dead Link could not be verified.
    case signatureInvalid

    /// X25519 key agreement failed to produce a shared secret.
    case keyAgreementFailed

    /// HKDF circle-key derivation failed.
    case keyDerivationFailed

    /// The SAS short codes do not match between peers.
    case shortCodeMismatch

    /// A handshake state-machine transition was invalid (e.g. confirming before verifying).
    case invalidStateTransition

    /// The handshake session has timed out.
    case sessionTimeout

    /// The Dead Link has already been consumed (one-time use).
    case deadLinkBurned

    /// An SQLite / Ledger operation failed.  The associated string contains the
    /// underlying SQLite error message when available.
    case ledgerError(String)

    // MARK: - Equatable

    public static func == (lhs: VeuAuthError, rhs: VeuAuthError) -> Bool {
        switch (lhs, rhs) {
        case (.deadLinkExpired, .deadLinkExpired),
             (.deadLinkInvalid, .deadLinkInvalid),
             (.signatureInvalid, .signatureInvalid),
             (.keyAgreementFailed, .keyAgreementFailed),
             (.keyDerivationFailed, .keyDerivationFailed),
             (.shortCodeMismatch, .shortCodeMismatch),
             (.invalidStateTransition, .invalidStateTransition),
             (.sessionTimeout, .sessionTimeout),
             (.deadLinkBurned, .deadLinkBurned):
            return true
        case (.ledgerError(let a), .ledgerError(let b)):
            return a == b
        default:
            return false
        }
    }
}
