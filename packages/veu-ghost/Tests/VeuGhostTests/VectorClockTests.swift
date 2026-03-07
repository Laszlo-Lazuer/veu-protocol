// VectorClockTests.swift — Veu Protocol: Vector Clock Unit Tests

import XCTest
@testable import VeuGhost

final class VectorClockTests: XCTestCase {

    // MARK: - Init

    func testEmptyClockHasNoState() {
        let vc = VectorClock()
        XCTAssertTrue(vc.state.isEmpty)
    }

    func testInitWithState() {
        let vc = VectorClock(state: ["alice": 5, "bob": 3])
        XCTAssertEqual(vc.sequence(for: "alice"), 5)
        XCTAssertEqual(vc.sequence(for: "bob"), 3)
    }

    // MARK: - Increment

    func testIncrementNewPeer() {
        var vc = VectorClock()
        let seq = vc.increment("alice")
        XCTAssertEqual(seq, 1)
        XCTAssertEqual(vc.sequence(for: "alice"), 1)
    }

    func testIncrementExistingPeer() {
        var vc = VectorClock(state: ["alice": 5])
        let seq = vc.increment("alice")
        XCTAssertEqual(seq, 6)
    }

    func testSequenceForUnknownPeerIsZero() {
        let vc = VectorClock()
        XCTAssertEqual(vc.sequence(for: "unknown"), 0)
    }

    // MARK: - Merge

    func testMergeTakesMax() {
        var local = VectorClock(state: ["alice": 5, "bob": 3])
        let remote = VectorClock(state: ["alice": 3, "bob": 7, "carol": 2])

        local.merge(remote)

        XCTAssertEqual(local.sequence(for: "alice"), 5)  // local was higher
        XCTAssertEqual(local.sequence(for: "bob"), 7)    // remote was higher
        XCTAssertEqual(local.sequence(for: "carol"), 2)  // new peer from remote
    }

    func testMergeEmptyIsNoOp() {
        var local = VectorClock(state: ["alice": 5])
        local.merge(VectorClock())
        XCTAssertEqual(local.sequence(for: "alice"), 5)
    }

    func testMergeIntoEmptyAdoptsRemote() {
        var local = VectorClock()
        local.merge(VectorClock(state: ["alice": 5, "bob": 3]))
        XCTAssertEqual(local.sequence(for: "alice"), 5)
        XCTAssertEqual(local.sequence(for: "bob"), 3)
    }

    // MARK: - Delta

    func testDeltaFindsAheadPeers() {
        let local = VectorClock(state: ["alice": 10, "bob": 5])
        let remote = VectorClock(state: ["alice": 7, "bob": 5])

        let delta = local.delta(from: remote)

        XCTAssertEqual(delta.count, 1)
        XCTAssertEqual(delta["alice"]?.after, 7)
        XCTAssertEqual(delta["alice"]?.upTo, 10)
    }

    func testDeltaEmptyWhenEqual() {
        let vc = VectorClock(state: ["alice": 5, "bob": 3])
        let delta = vc.delta(from: vc)
        XCTAssertTrue(delta.isEmpty)
    }

    func testDeltaEmptyWhenRemoteAhead() {
        let local = VectorClock(state: ["alice": 3])
        let remote = VectorClock(state: ["alice": 5])
        let delta = local.delta(from: remote)
        XCTAssertTrue(delta.isEmpty)
    }

    func testDeltaNewPeerInLocal() {
        let local = VectorClock(state: ["alice": 5, "carol": 2])
        let remote = VectorClock(state: ["alice": 5])

        let delta = local.delta(from: remote)
        XCTAssertEqual(delta.count, 1)
        XCTAssertEqual(delta["carol"]?.after, 0)
        XCTAssertEqual(delta["carol"]?.upTo, 2)
    }

    // MARK: - Dominates / Concurrent

    func testDominatesSelf() {
        let vc = VectorClock(state: ["alice": 5, "bob": 3])
        XCTAssertTrue(vc.dominates(vc))
    }

    func testDominatesEmpty() {
        let vc = VectorClock(state: ["alice": 5])
        XCTAssertTrue(vc.dominates(VectorClock()))
    }

    func testDoesNotDominateAhead() {
        let local = VectorClock(state: ["alice": 3])
        let remote = VectorClock(state: ["alice": 5])
        XCTAssertFalse(local.dominates(remote))
    }

    func testConcurrentClocks() {
        let a = VectorClock(state: ["alice": 5, "bob": 3])
        let b = VectorClock(state: ["alice": 3, "bob": 7])
        XCTAssertTrue(a.isConcurrent(with: b))
    }

    func testNotConcurrentWhenOneDominates() {
        let a = VectorClock(state: ["alice": 5, "bob": 7])
        let b = VectorClock(state: ["alice": 3, "bob": 5])
        XCTAssertFalse(a.isConcurrent(with: b))
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = VectorClock(state: ["alice": 42, "bob": 7])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VectorClock.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testCodableEmptyClock() throws {
        let original = VectorClock()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VectorClock.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
