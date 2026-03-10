// VeuMeshError.swift — Veu Protocol: Mesh Layer Error Types

import Foundation

/// Errors produced by the `VeuMesh` module.
public enum VeuMeshError: Error, Equatable {
    /// No transport is currently available.
    case noTransportAvailable

    /// A specific transport failed to start.
    case transportFailed(String)

    /// WebSocket relay connection failed.
    case relayConnectionFailed(String)

    /// Relay server returned an error.
    case relayError(String)

    /// Bluetooth/AWDL mesh discovery failed.
    case meshDiscoveryFailed(String)

    /// Message routing failed (e.g., TTL expired, no route to peer).
    case routingFailed(String)

    /// Configuration error (e.g., missing relay URL).
    case configurationError(String)

    // MARK: - Equatable

    public static func == (lhs: VeuMeshError, rhs: VeuMeshError) -> Bool {
        switch (lhs, rhs) {
        case (.noTransportAvailable, .noTransportAvailable):
            return true
        case (.transportFailed(let a), .transportFailed(let b)),
             (.relayConnectionFailed(let a), .relayConnectionFailed(let b)),
             (.relayError(let a), .relayError(let b)),
             (.meshDiscoveryFailed(let a), .meshDiscoveryFailed(let b)),
             (.routingFailed(let a), .routingFailed(let b)),
             (.configurationError(let a), .configurationError(let b)):
            return a == b
        default:
            return false
        }
    }
}
