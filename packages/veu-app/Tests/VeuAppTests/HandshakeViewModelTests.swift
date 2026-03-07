import XCTest
@testable import VeuApp
import VeuAuth

final class HandshakeViewModelTests: XCTestCase {

    func testInitialState() throws {
        let state = try AppState.bootstrap()
        let vm = HandshakeViewModel(appState: state)

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.deadLinkURI)
        XCTAssertNil(vm.shortCode)
        XCTAssertNil(vm.auraColorHex)
        XCTAssertNil(vm.circleKey)
        XCTAssertNil(vm.errorMessage)
    }

    func testInitiateTransitionsToInitiating() throws {
        let state = try AppState.bootstrap()
        let vm = HandshakeViewModel(appState: state)

        try vm.initiate()

        XCTAssertEqual(vm.phase, .initiating)
        XCTAssertNotNil(vm.deadLinkURI)
        XCTAssertTrue(vm.deadLinkURI!.hasPrefix("veu://handshake?"))
    }

    func testFullHandshakeFlow() throws {
        // Alice initiates
        let aliceState = try AppState.bootstrap()
        let aliceVM = HandshakeViewModel(appState: aliceState)
        try aliceVM.initiate()

        guard let uri = aliceVM.deadLinkURI else {
            XCTFail("No Dead Link URI generated")
            return
        }

        // Bob responds
        let bobState = try AppState.bootstrap()
        let bobVM = HandshakeViewModel(appState: bobState, circleID: aliceVM.circleID)
        let bobPubKeyData = try bobVM.respond(to: uri)

        XCTAssertEqual(bobVM.phase, .verifying)
        XCTAssertNotNil(bobVM.shortCode)
        XCTAssertNotNil(bobVM.auraColorHex)

        // Alice receives Bob's public key
        try aliceVM.receiveResponse(remotePublicKeyData: bobPubKeyData)

        XCTAssertEqual(aliceVM.phase, .verifying)
        XCTAssertNotNil(aliceVM.shortCode)

        // Both should have the same short code
        XCTAssertEqual(aliceVM.shortCode, bobVM.shortCode)
        XCTAssertEqual(aliceVM.auraColorHex, bobVM.auraColorHex)

        // Both confirm
        try aliceVM.confirm()
        try bobVM.confirm()

        XCTAssertEqual(aliceVM.phase, .confirmed)
        XCTAssertEqual(bobVM.phase, .confirmed)
        XCTAssertNotNil(aliceVM.circleKey)
        XCTAssertNotNil(bobVM.circleKey)

        // Circle registered in app state
        XCTAssertEqual(aliceState.activeCircleID, aliceVM.circleID)
        XCTAssertTrue(aliceState.circleIDs.contains(aliceVM.circleID))
    }

    func testRejectTransitionsToGhost() throws {
        let state = try AppState.bootstrap()
        let vm = HandshakeViewModel(appState: state)
        try vm.initiate()

        // Simulate getting to verifying state via a full handshake
        let bobState = try AppState.bootstrap()
        let bobVM = HandshakeViewModel(appState: bobState, circleID: vm.circleID)
        let pubKey = try bobVM.respond(to: vm.deadLinkURI!)
        try vm.receiveResponse(remotePublicKeyData: pubKey)

        vm.reject()

        XCTAssertEqual(vm.phase, .ghost)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testResetClearsState() throws {
        let state = try AppState.bootstrap()
        let vm = HandshakeViewModel(appState: state)
        try vm.initiate()

        vm.reset()

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.deadLinkURI)
        XCTAssertNil(vm.shortCode)
        XCTAssertNil(vm.circleKey)
    }

    func testExpireTransitionsToDeadLink() throws {
        let state = try AppState.bootstrap()
        let vm = HandshakeViewModel(appState: state)
        try vm.initiate()

        vm.expire()

        XCTAssertEqual(vm.phase, .deadLink)
        XCTAssertNotNil(vm.errorMessage)
    }
}
