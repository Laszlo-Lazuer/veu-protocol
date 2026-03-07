// VectorClock.swift — Veu Protocol: Vector Clock for Delta-Sync
//
// Each device maintains a state vector: {PeerID: LastKnownSequence}.
// When two peers connect, they exchange vector clocks to determine which
// artifacts need to be transmitted (the "delta").

import Foundation

/// A vector clock mapping device IDs to their last known sequence numbers.
///
/// Used by the Ghost Network delta-sync protocol (SYNC.md) to determine
/// which artifacts a peer is missing without revealing content.
public struct VectorClock: Codable, Equatable, Sendable {

    /// The underlying state: `deviceID → sequence number`.
    public private(set) var state: [String: UInt64]

    /// Create an empty vector clock.
    public init() {
        self.state = [:]
    }

    /// Create a vector clock with the given initial state.
    public init(state: [String: UInt64]) {
        self.state = state
    }

    // MARK: - Mutations

    /// Increment the sequence number for a peer (or set to 1 if unseen).
    ///
    /// - Parameter peerID: The device ID whose sequence should advance.
    /// - Returns: The new sequence number.
    @discardableResult
    public mutating func increment(_ peerID: String) -> UInt64 {
        let next = (state[peerID] ?? 0) + 1
        state[peerID] = next
        return next
    }

    /// Get the sequence number for a peer (0 if unseen).
    public func sequence(for peerID: String) -> UInt64 {
        state[peerID] ?? 0
    }

    /// Set the sequence number for a peer to a specific value.
    ///
    /// - Parameters:
    ///   - peerID: The device ID.
    ///   - sequence: The sequence number to set.
    public mutating func set(_ peerID: String, to sequence: UInt64) {
        state[peerID] = sequence
    }

    // MARK: - Merge

    /// Merge a remote vector clock into this one, taking the maximum
    /// sequence number for each peer.
    ///
    /// - Parameter remote: The peer's vector clock.
    public mutating func merge(_ remote: VectorClock) {
        for (peerID, remoteSeq) in remote.state {
            let localSeq = state[peerID] ?? 0
            state[peerID] = max(localSeq, remoteSeq)
        }
    }

    // MARK: - Delta Calculation

    /// Calculate which peer sequences are ahead in `self` compared to `remote`.
    ///
    /// Returns a dictionary of `{peerID: (remoteHas, localHas)}` for each peer
    /// where the local clock is strictly ahead of the remote clock.
    ///
    /// - Parameter remote: The peer's vector clock.
    /// - Returns: Peers and sequence ranges that the remote is missing.
    public func delta(from remote: VectorClock) -> [String: (after: UInt64, upTo: UInt64)] {
        var result: [String: (after: UInt64, upTo: UInt64)] = [:]
        for (peerID, localSeq) in state {
            let remoteSeq = remote.sequence(for: peerID)
            if localSeq > remoteSeq {
                result[peerID] = (after: remoteSeq, upTo: localSeq)
            }
        }
        return result
    }

    /// Check if this clock is concurrent with (neither dominates) another.
    ///
    /// - Parameter other: The other vector clock.
    /// - Returns: `true` if neither clock dominates the other.
    public func isConcurrent(with other: VectorClock) -> Bool {
        let allPeers = Set(state.keys).union(other.state.keys)
        var selfAhead = false
        var otherAhead = false
        for peer in allPeers {
            let s = sequence(for: peer)
            let o = other.sequence(for: peer)
            if s > o { selfAhead = true }
            if o > s { otherAhead = true }
        }
        return selfAhead && otherAhead
    }

    /// Check if this clock dominates (is strictly ahead of or equal to) another.
    ///
    /// - Parameter other: The other vector clock.
    /// - Returns: `true` if every sequence in `other` is ≤ the corresponding sequence in `self`.
    public func dominates(_ other: VectorClock) -> Bool {
        for (peerID, otherSeq) in other.state {
            if sequence(for: peerID) < otherSeq { return false }
        }
        return true
    }
}
