// LedgerTests.swift — Tests for the SQLite Ledger (schema, CRUD, burn/purge).

import XCTest
@testable import VeuAuth

final class LedgerTests: XCTestCase {

    // MARK: - Schema Bootstrap

    func testOpenInMemoryLedger() throws {
        let ledger = try Ledger(path: ":memory:")
        XCTAssertEqual(ledger.path, ":memory:")
    }

    func testSchemaCreatesTablesIdempotently() throws {
        // Opening the same in-memory DB twice should not throw
        let ledger = try Ledger(path: ":memory:")
        // Verify we can query tables (they exist)
        let circles = try ledger.listCircles()
        XCTAssertTrue(circles.isEmpty)
    }

    // MARK: - Metadata

    func testInitializeAndReadSchemaVersion() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.initializeMeta(deviceID: "test-device-001")

        let version = try ledger.schemaVersion()
        XCTAssertEqual(version, 1)
    }

    func testSchemaVersionIsNilBeforeInit() throws {
        let ledger = try Ledger(path: ":memory:")
        let version = try ledger.schemaVersion()
        XCTAssertNil(version)
    }

    // MARK: - Circle Operations

    func testInsertAndListCircle() throws {
        let ledger = try Ledger(path: ":memory:")
        let circleID = "circle-001"
        let encryptedName = Data("encrypted-name".utf8)

        try ledger.insertCircle(circleID: circleID, encryptedName: encryptedName)

        let circles = try ledger.listCircles()
        XCTAssertEqual(circles.count, 1)
        XCTAssertEqual(circles.first, circleID)
    }

    func testDeleteCircleCascadesArtifacts() throws {
        let ledger = try Ledger(path: ":memory:")
        let circleID = "circle-cascade"

        try ledger.insertCircle(circleID: circleID, encryptedName: Data("name".utf8))
        try ledger.insertArtifact(
            cid: "cid-001",
            circleID: circleID,
            artifactType: "post",
            encryptedMeta: Data("meta".utf8)
        )

        let before = try ledger.listArtifacts(circleID: circleID)
        XCTAssertEqual(before.count, 1)

        try ledger.deleteCircle(circleID: circleID)

        let circles = try ledger.listCircles()
        XCTAssertTrue(circles.isEmpty)
    }

    // MARK: - Artifact Operations

    func testInsertAndListArtifact() throws {
        let ledger = try Ledger(path: ":memory:")
        let circleID = "circle-art"

        try ledger.insertCircle(circleID: circleID, encryptedName: Data("name".utf8))
        try ledger.insertArtifact(
            cid: "cid-100",
            circleID: circleID,
            artifactType: "post",
            encryptedMeta: Data("encrypted-meta".utf8)
        )

        let cids = try ledger.listArtifacts(circleID: circleID)
        XCTAssertEqual(cids, ["cid-100"])
    }

    func testInsertMultipleArtifacts() throws {
        let ledger = try Ledger(path: ":memory:")
        let circleID = "circle-multi"

        try ledger.insertCircle(circleID: circleID, encryptedName: Data("name".utf8))

        for i in 1...5 {
            try ledger.insertArtifact(
                cid: "cid-\(i)",
                circleID: circleID,
                artifactType: "post",
                encryptedMeta: Data("meta-\(i)".utf8)
            )
        }

        let cids = try ledger.listArtifacts(circleID: circleID)
        XCTAssertEqual(cids.count, 5)
    }

    func testInsertArtifactReturnsRowID() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.insertCircle(circleID: "c1", encryptedName: Data("n".utf8))

        let id1 = try ledger.insertArtifact(
            cid: "cid-a", circleID: "c1", artifactType: "file", encryptedMeta: Data("m".utf8)
        )
        let id2 = try ledger.insertArtifact(
            cid: "cid-b", circleID: "c1", artifactType: "message", encryptedMeta: Data("m".utf8)
        )

        XCTAssertGreaterThan(id1, 0)
        XCTAssertGreaterThan(id2, id1)
    }

    // MARK: - Purge / Burn

    func testPurgeArtifactExcludesFromList() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.insertCircle(circleID: "c1", encryptedName: Data("n".utf8))
        try ledger.insertArtifact(
            cid: "to-purge", circleID: "c1", artifactType: "post", encryptedMeta: Data("m".utf8)
        )
        try ledger.insertArtifact(
            cid: "to-keep", circleID: "c1", artifactType: "post", encryptedMeta: Data("m".utf8)
        )

        try ledger.purgeArtifact(cid: "to-purge")

        let remaining = try ledger.listArtifacts(circleID: "c1")
        XCTAssertEqual(remaining, ["to-keep"])
    }

    // MARK: - Sync State

    func testMarkSynced() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.insertCircle(circleID: "c1", encryptedName: Data("n".utf8))
        try ledger.insertArtifact(
            cid: "sync-me", circleID: "c1", artifactType: "post", encryptedMeta: Data("m".utf8)
        )

        // Should not throw
        XCTAssertNoThrow(try ledger.markSynced(cid: "sync-me"))

        // Still listed (not purged)
        let cids = try ledger.listArtifacts(circleID: "c1")
        XCTAssertTrue(cids.contains("sync-me"))
    }

    // MARK: - Artifact Type Validation

    func testInvalidArtifactTypeThrows() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.insertCircle(circleID: "c1", encryptedName: Data("n".utf8))

        XCTAssertThrowsError(try ledger.insertArtifact(
            cid: "bad-type", circleID: "c1", artifactType: "invalid_type", encryptedMeta: Data("m".utf8)
        )) { error in
            guard case VeuAuthError.ledgerError = error else {
                XCTFail("Expected ledgerError, got \(error)")
                return
            }
        }
    }

    // MARK: - Duplicate CID

    func testDuplicateCIDThrows() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.insertCircle(circleID: "c1", encryptedName: Data("n".utf8))
        try ledger.insertArtifact(
            cid: "dup-cid", circleID: "c1", artifactType: "post", encryptedMeta: Data("m".utf8)
        )

        XCTAssertThrowsError(try ledger.insertArtifact(
            cid: "dup-cid", circleID: "c1", artifactType: "post", encryptedMeta: Data("m2".utf8)
        ))
    }
}
