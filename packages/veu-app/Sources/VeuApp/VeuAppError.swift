import Foundation

/// Errors raised by the VeuApp integration layer.
public enum VeuAppError: Error, Equatable {
    case identityCorrupted
    case noActiveCircle
    case handshakeInProgress
    case handshakeNotReady
    case artifactNotFound(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case networkUnavailable
    case ledgerError(String)
    case invalidData(String)
}
