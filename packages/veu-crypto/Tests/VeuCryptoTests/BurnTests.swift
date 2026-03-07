import XCTest
@testable import VeuCrypto

final class BurnTests: XCTestCase {

    // MARK: - Single burn

    func testAfterBurnIsBurnedReturnsTrue() {
        let engine      = BurnEngine()
        let artifactKey = ArtifactKey.generate()
        let id          = UUID()

        XCTAssertFalse(engine.isBurned(artifactID: id))

        engine.burn(artifactKey: artifactKey, artifactID: id)

        XCTAssertTrue(engine.isBurned(artifactID: id))
    }

    // MARK: - Unburned IDs are not affected

    func testUnburnedIdReturnsFalse() {
        let engine      = BurnEngine()
        let artifactKey = ArtifactKey.generate()
        let burned      = UUID()
        let untouched   = UUID()

        engine.burn(artifactKey: artifactKey, artifactID: burned)

        XCTAssertTrue(engine.isBurned(artifactID: burned))
        XCTAssertFalse(engine.isBurned(artifactID: untouched))
    }

    // MARK: - burnAll

    func testBurnAllMarksManyIDsAsBurned() {
        let engine = BurnEngine()
        let ids    = (0..<5).map { _ in UUID() }

        XCTAssertTrue(ids.allSatisfy { !engine.isBurned(artifactID: $0) })

        engine.burnAll(artifactIDs: ids)

        XCTAssertTrue(ids.allSatisfy { engine.isBurned(artifactID: $0) })
    }

    // MARK: - Derived key determinism + burn interaction

    func testDerivedKeyIsDeterministic() throws {
        let circleKey   = CircleKey.generate()
        let artifactID  = UUID()

        let key1 = try ArtifactKey.derived(from: circleKey, artifactID: artifactID)
        let key2 = try ArtifactKey.derived(from: circleKey, artifactID: artifactID)

        let data1 = key1.symmetricKey.withUnsafeBytes { Data($0) }
        let data2 = key2.symmetricKey.withUnsafeBytes { Data($0) }

        XCTAssertEqual(data1, data2)
    }

    func testDifferentArtifactIDsProduceDifferentKeys() throws {
        let circleKey = CircleKey.generate()
        let id1       = UUID()
        let id2       = UUID()

        let key1 = try ArtifactKey.derived(from: circleKey, artifactID: id1)
        let key2 = try ArtifactKey.derived(from: circleKey, artifactID: id2)

        let data1 = key1.symmetricKey.withUnsafeBytes { Data($0) }
        let data2 = key2.symmetricKey.withUnsafeBytes { Data($0) }

        XCTAssertNotEqual(data1, data2)
    }
}
