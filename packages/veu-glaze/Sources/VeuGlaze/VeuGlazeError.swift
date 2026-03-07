// VeuGlazeError.swift — Veu Protocol: Glaze Engine Error Types

import Foundation

/// Errors produced by the `VeuGlaze` module.
public enum VeuGlazeError: Error, Equatable {
    /// No Metal-capable GPU device is available.
    case metalDeviceUnavailable

    /// The Metal shader source failed to compile.
    case shaderCompilationFailed(String)

    /// The Metal render pipeline could not be created.
    case pipelineCreationFailed(String)

    /// Biometric authentication is not available on this device.
    case biometricUnavailable

    /// Biometric authentication failed or was cancelled by the user.
    case biometricFailed(String)

    /// A rendering error occurred during a draw call.
    case renderError(String)

    // MARK: - Equatable

    public static func == (lhs: VeuGlazeError, rhs: VeuGlazeError) -> Bool {
        switch (lhs, rhs) {
        case (.metalDeviceUnavailable, .metalDeviceUnavailable),
             (.biometricUnavailable, .biometricUnavailable):
            return true
        case (.shaderCompilationFailed(let a), .shaderCompilationFailed(let b)),
             (.pipelineCreationFailed(let a), .pipelineCreationFailed(let b)),
             (.biometricFailed(let a), .biometricFailed(let b)),
             (.renderError(let a), .renderError(let b)):
            return a == b
        default:
            return false
        }
    }
}
