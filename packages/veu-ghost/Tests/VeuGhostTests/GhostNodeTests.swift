// GhostNodeTests.swift — Veu Protocol: GhostNode Lifecycle Tests

import XCTest
@testable import VeuGhost
import VeuAuth

final class GhostNodeTests: XCTestCase {

    private func makeLedger() throws -> Ledger {
        let ledger = try Ledger(path: ":memory:")
        try ledger.initializeMeta(deviceID: "test-device")
        return ledger
    }

    private var circleKey: Data { Data(repeating: 0xCC, count: 32) }

    // MARK: - Init

    func testGhostNodeCreation() throws {
        let ledger = try makeLedger()
        let node = GhostNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        XCTAssertEqual(node.deviceID, "device-1")
        XCTAssertEqual(node.circleID, "circle-abc")
        XCTAssertEqual(node.circleKey, circleKey)
        XCTAssertFalse(node.isRunning)
    }

    func testNodePulseHasCorrectTopicHash() throws {
        let ledger = try makeLedger()
        let node = GhostNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        let expectedHash = GhostConnection.circleTopicHash(circleKey: circleKey)
        XCTAssertEqual(node.pulse.topicHash, expectedHash)
    }

    // MARK: - Lifecycle

    func testStartAndStop() throws {
        let ledger = try makeLedger()
        let node = GhostNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        try node.start()
        XCTAssertTrue(node.isRunning)

        node.stop()
        XCTAssertFalse(node.isRunning)
    }

    func testDoubleStartIsNoOp() throws {
        let ledger = try makeLedger()
        let node = GhostNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        try node.start()
        try node.start() // should not throw
        XCTAssertTrue(node.isRunning)
        node.stop()
    }

    // MARK: - SyncEngine Integration

    func testNodeSyncEngineHasCorrectDeviceID() throws {
        let ledger = try makeLedger()
        let node = GhostNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        XCTAssertEqual(node.syncEngine.deviceID, "device-1")
    }

    func testNodeSyncEngineDelegateIsForwarded() throws {
        let ledger = try makeLedger()
        let node = GhostNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        let delegate = MockSyncDelegate()
        node.syncDelegate = delegate
        XCTAssertTrue(node.syncEngine.delegate === delegate)
    }

    // MARK: - LocalPulse Service Type

    func testLocalPulseServiceType() {
        XCTAssertEqual(LocalPulse.serviceType, "_veu-ghost._tcp")
    }
}
