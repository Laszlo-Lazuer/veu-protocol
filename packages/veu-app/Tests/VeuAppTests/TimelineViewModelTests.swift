import XCTest
@testable import VeuApp
import VeuAuth
import VeuCrypto

final class TimelineViewModelTests: XCTestCase {

    private func makeStateWithCircle() throws -> (AppState, String) {
        // Bootstrap two identities and complete a handshake to get a circle
        let aliceState = try AppState.bootstrap()
        let aliceVM = HandshakeViewModel(appState: aliceState)
        try aliceVM.initiate()
        let uri = aliceVM.deadLinkURI!

        let bobState = try AppState.bootstrap()
        let bobVM = HandshakeViewModel(appState: bobState, circleID: aliceVM.circleID)
        let pubKey = try bobVM.respond(to: uri)
        try aliceVM.receiveResponse(remotePublicKeyData: pubKey)
        try aliceVM.confirm()

        return (aliceState, aliceVM.circleID)
    }

    func testEmptyTimeline() throws {
        let (state, _) = try makeStateWithCircle()
        let vm = TimelineViewModel(appState: state)
        try vm.reload()

        XCTAssertTrue(vm.entries.isEmpty)
    }

    func testComposeAddsEntry() throws {
        let (state, _) = try makeStateWithCircle()
        let vm = TimelineViewModel(appState: state)

        let result = try vm.compose(data: Data("hello world".utf8))

        XCTAssertFalse(result.cid.isEmpty)
        XCTAssertFalse(result.encryptedMeta.isEmpty)
        XCTAssertEqual(vm.entries.count, 1)
    }

    func testMultipleComposeAccumulatesEntries() throws {
        let (state, _) = try makeStateWithCircle()
        let vm = TimelineViewModel(appState: state)

        try vm.compose(data: Data("first".utf8))
        try vm.compose(data: Data("second".utf8))
        try vm.compose(data: Data("third".utf8))

        XCTAssertEqual(vm.entries.count, 3)
    }

    func testBurnRemovesEntry() throws {
        let (state, _) = try makeStateWithCircle()
        let vm = TimelineViewModel(appState: state)

        let result = try vm.compose(data: Data("ephemeral".utf8))
        XCTAssertEqual(vm.entries.count, 1)

        try vm.burn(cid: result.cid)

        // After purge, the artifact is no longer in the list
        XCTAssertEqual(vm.entries.count, 0)
    }

    func testGlazeSeedColorsAreDeterministic() throws {
        let (state, _) = try makeStateWithCircle()
        let vm = TimelineViewModel(appState: state)

        try vm.compose(data: Data("test".utf8))

        let entry = vm.entries.first!
        let color = entry.glazeSeedColor

        // Reload and verify colors are stable
        try vm.reload()
        let reloaded = vm.entries.first { $0.cid == entry.cid }!

        XCTAssertEqual(color.r, reloaded.glazeSeedColor.r)
        XCTAssertEqual(color.g, reloaded.glazeSeedColor.g)
        XCTAssertEqual(color.b, reloaded.glazeSeedColor.b)
    }

    func testComposeWithoutCircleThrows() throws {
        let state = try AppState.bootstrap()
        let vm = TimelineViewModel(appState: state)

        XCTAssertThrowsError(try vm.compose(data: Data("no circle".utf8))) { error in
            XCTAssertEqual(error as? VeuAppError, .noActiveCircle)
        }
    }

    func testBurnExpiredPurgesOldArtifacts() throws {
        let (state, _) = try makeStateWithCircle()
        let vm = TimelineViewModel(appState: state)

        // Insert artifact with burn time in the past
        let pastBurn = Int(Date().timeIntervalSince1970) - 3600
        try vm.compose(data: Data("old".utf8), burnAfter: pastBurn)
        XCTAssertEqual(vm.entries.count, 1)

        try vm.burnExpired()
        XCTAssertEqual(vm.entries.count, 0)
    }

    func testReloadWithNoCircleReturnsEmpty() throws {
        let state = try AppState.bootstrap()
        let vm = TimelineViewModel(appState: state)
        try vm.reload()
        XCTAssertTrue(vm.entries.isEmpty)
    }
}
