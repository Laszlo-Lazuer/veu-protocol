// SyncEngineTests.swift — Veu Protocol: Delta-Sync Engine Tests

import XCTest
@testable import VeuGhost
import VeuAuth

/// Mock delegate that records sync events for assertion.
final class MockSyncDelegate: SyncEngineDelegate {
    var receivedArtifacts: [(cid: String, circleID: String)] = []
    var processedBurns: [(cid: String, circleID: String)] = []
    var completedSyncs: [String] = []
    var errors: [VeuGhostError] = []

    func syncEngine(_ engine: SyncEngine, didReceiveArtifact cid: String, circleID: String) {
        receivedArtifacts.append((cid, circleID))
    }

    func syncEngine(_ engine: SyncEngine, didProcessBurn cid: String, circleID: String) {
        processedBurns.append((cid, circleID))
    }

    func syncEngine(_ engine: SyncEngine, didCompleteSyncWith peerDeviceID: String) {
        completedSyncs.append(peerDeviceID)
    }

    func syncEngine(_ engine: SyncEngine, didFailWith error: VeuGhostError) {
        errors.append(error)
    }
}

final class SyncEngineTests: XCTestCase {

    private func makeLedger() throws -> Ledger {
        let ledger = try Ledger(path: ":memory:")
        try ledger.initializeMeta(deviceID: "test-device")
        return ledger
    }

    // MARK: - Clock Management

    func testRecordLocalArtifactIncrementsSequence() throws {
        let ledger = try makeLedger()
        let engine = SyncEngine(deviceID: "device-1", ledger: ledger)

        let seq1 = engine.recordLocalArtifact(circleID: "circle-1")
        XCTAssertEqual(seq1, 1)

        let seq2 = engine.recordLocalArtifact(circleID: "circle-1")
        XCTAssertEqual(seq2, 2)
    }

    func testClockForUnknownCircleIsEmpty() throws {
        let ledger = try makeLedger()
        let engine = SyncEngine(deviceID: "device-1", ledger: ledger)
        let clock = engine.clock(for: "nonexistent")
        XCTAssertTrue(clock.state.isEmpty)
    }

    func testClocksArePerCircle() throws {
        let ledger = try makeLedger()
        let engine = SyncEngine(deviceID: "device-1", ledger: ledger)

        engine.recordLocalArtifact(circleID: "circle-a")
        engine.recordLocalArtifact(circleID: "circle-a")
        engine.recordLocalArtifact(circleID: "circle-b")

        XCTAssertEqual(engine.clock(for: "circle-a").sequence(for: "device-1"), 2)
        XCTAssertEqual(engine.clock(for: "circle-b").sequence(for: "device-1"), 1)
    }

    // MARK: - Burn Notice Handling

    func testHandleBurnNoticePurgesArtifact() throws {
        let ledger = try makeLedger()
        try ledger.insertCircle(circleID: "circle-1", encryptedName: Data("test".utf8))
        try ledger.insertArtifact(cid: "cid-to-burn", circleID: "circle-1",
                                   artifactType: "post", encryptedMeta: Data("meta".utf8))

        let engine = SyncEngine(deviceID: "device-1", ledger: ledger)
        let delegate = MockSyncDelegate()
        engine.delegate = delegate

        let notice = GhostMessage.BurnNoticePayload(
            cid: "cid-to-burn", circleID: "circle-1", originDeviceID: "device-2"
        )
        engine.handleBurnNotice(notice)

        XCTAssertEqual(delegate.processedBurns.count, 1)
        XCTAssertEqual(delegate.processedBurns.first?.cid, "cid-to-burn")

        // Artifact should no longer appear in active list
        let active = try ledger.listArtifacts(circleID: "circle-1")
        XCTAssertFalse(active.contains("cid-to-burn"))
    }

    // MARK: - SyncEngine + VectorClock Integration

    func testDeltaSyncIdentifiesMissingArtifacts() throws {
        let ledger = try makeLedger()
        let engine = SyncEngine(
            deviceID: "device-1",
            ledger: ledger,
            clocks: ["circle-1": VectorClock(state: ["device-1": 5, "device-2": 3])]
        )

        let remoteClock = VectorClock(state: ["device-1": 5, "device-2": 1])
        let localClock = engine.clock(for: "circle-1")
        let delta = localClock.delta(from: remoteClock)

        // device-2 is ahead locally (3 vs 1)
        XCTAssertEqual(delta["device-2"]?.after, 1)
        XCTAssertEqual(delta["device-2"]?.upTo, 3)
        // device-1 is equal (5 vs 5) — no delta
        XCTAssertNil(delta["device-1"])
    }

    func testInitialClockIsEmpty() throws {
        let ledger = try makeLedger()
        let engine = SyncEngine(deviceID: "device-1", ledger: ledger)
        XCTAssertTrue(engine.clocks.isEmpty)
    }

    // MARK: - Error Types

    func testVeuGhostErrorEquality() {
        XCTAssertEqual(VeuGhostError.timeout, VeuGhostError.timeout)
        XCTAssertEqual(VeuGhostError.syncFailed("x"), VeuGhostError.syncFailed("x"))
        XCTAssertNotEqual(VeuGhostError.syncFailed("x"), VeuGhostError.syncFailed("y"))
        XCTAssertNotEqual(VeuGhostError.timeout, VeuGhostError.syncFailed("x"))
    }
}
