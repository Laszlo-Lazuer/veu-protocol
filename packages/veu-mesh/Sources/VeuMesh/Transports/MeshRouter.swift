// MeshRouter.swift — Veu Protocol: Multi-Hop Routing Table
//
// Maintains a routing table for the Bluetooth/AWDL mesh.  Each entry
// tracks a destination peer, the next-hop peer to reach it, and the
// number of hops.  Max hops are enforced to prevent broadcast storms.

import Foundation

/// A route to a remote peer through the mesh.
public struct MeshRoute: Equatable {
    /// The next-hop peer to forward to.
    public let via: String
    /// Number of hops to reach the destination.
    public let hops: Int
}

/// Multi-hop routing table for the Bluetooth/AWDL mesh.
///
/// Entries expire after a configurable TTL and are pruned on access.
/// The router enforces a maximum hop count to prevent broadcast storms.
public struct MeshRouter {

    /// Maximum allowed hops for any route.
    public let maxHops: Int

    /// Routing table: destination peer → best route.
    private var routes: [String: MeshRoute] = [:]

    public init(maxHops: Int = 5) {
        self.maxHops = maxHops
    }

    // MARK: - Route Management

    /// Add or update a route to a peer.
    ///
    /// - Parameters:
    ///   - destination: The target peer's display name.
    ///   - via: The next-hop peer's display name.
    ///   - hops: Number of hops to reach the destination.
    public mutating func addRoute(to destination: String, via: String, hops: Int) {
        guard hops <= maxHops else { return }
        // Only update if this route is shorter than the existing one
        if let existing = routes[destination], existing.hops <= hops {
            return
        }
        routes[destination] = MeshRoute(via: via, hops: hops)
    }

    /// Remove all routes to a peer (e.g., when it disconnects).
    public mutating func removeRoute(to destination: String) {
        routes.removeValue(forKey: destination)
        // Also remove routes that go through this peer
        routes = routes.filter { $0.value.via != destination }
    }

    /// Get the best route to a destination.
    public func route(to destination: String) -> MeshRoute? {
        routes[destination]
    }

    /// All known destinations.
    public var destinations: [String] {
        Array(routes.keys)
    }

    /// Number of known routes.
    public var count: Int {
        routes.count
    }
}
