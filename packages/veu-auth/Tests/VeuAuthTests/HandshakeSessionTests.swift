// HandshakeSessionTests.swift — Tests for the handshake session orchestrator.

import XCTest
@testable import VeuAuth
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import VeuCrypto

final class HandshakeSessionTests: XCTestCase {

    // MARK: - Initiator Flow

    func testInitiateTransitionsToInitiating() throws {
        let session = HandshakeSession()
        XCTAssertEqual(session.phase, .idle)

        try session.initiate()
        XCTAssertEqual(session.phase, .initiating)
        XCTAssertNotNil(session.deadLink)
    }

    func testInitiateTwiceThrowsInvalidState() throws {
        let session = HandshakeSession()
        try session.initiate()

        XCTAssertThrowsError(try session.initiate()) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.invalidStateTransition)
        }
    }

    // MARK: - Responder Flow

    func testRespondTransitionsToVerifying() throws {
        // Alice initiates
        let alice = HandshakeSession(circleID: "test")
        let deadLink = try alice.initiate()
        let uri = deadLink.toURI()

        // Bob responds
        let bob = HandshakeSession(circleID: "test")
        let bobPubKeyData = try bob.respond(to: uri)

        XCTAssertEqual(bob.phase, .verifying)
        XCTAssertNotNil(bob.shortCode)
        XCTAssertNotNil(bob.auraColorHex)
        XCTAssertEqual(bobPubKeyData.count, 32)
    }

    func testRespondToExpiredLinkThrows() throws {
        let alice = HandshakeSession()
        let deadLink = try alice.initiate(ttl: -10) // Already expired
        let uri = deadLink.toURI()

        let bob = HandshakeSession()
        XCTAssertThrowsError(try bob.respond(to: uri)) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.deadLinkExpired)
        }
    }

    // MARK: - Full Handshake (Alice + Bob)

    func testFullHandshakeSuccess() throws {
        let circleID = "family-circle"

        // Alice initiates
        let alice = HandshakeSession(circleID: circleID)
        let deadLink = try alice.initiate()
        let uri = deadLink.toURI()

        // Bob responds and gets his public key to send back
        let bob = HandshakeSession(circleID: circleID)
        let bobPubKeyData = try bob.respond(to: uri)

        // Alice receives Bob's public key
        try alice.receiveResponse(remotePublicKeyData: bobPubKeyData)

        // Both should be in verifying with matching short codes
        XCTAssertEqual(alice.phase, .verifying)
        XCTAssertEqual(bob.phase, .verifying)
        XCTAssertEqual(alice.shortCode, bob.shortCode)
        XCTAssertEqual(alice.auraColorHex, bob.auraColorHex)

        // Both confirm
        try alice.confirm()
        try bob.confirm()

        XCTAssertEqual(alice.phase, .confirmed)
        XCTAssertEqual(bob.phase, .confirmed)

        // Circle keys should be identical
        let aliceKeyData = alice.circleKey!.symmetricKey.withUnsafeBytes { Data($0) }
        let bobKeyData = bob.circleKey!.symmetricKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(aliceKeyData, bobKeyData)
    }

    func testShortCodeIs8DigitHex() throws {
        let circleID = "test"
        let alice = HandshakeSession(circleID: circleID)
        let deadLink = try alice.initiate()
        let bob = HandshakeSession(circleID: circleID)
        let bobPK = try bob.respond(to: deadLink.toURI())
        try alice.receiveResponse(remotePublicKeyData: bobPK)

        let code = alice.shortCode!
        XCTAssertEqual(code.count, 8)
        let hexChars = CharacterSet(charactersIn: "0123456789ABCDEF")
        XCTAssertTrue(code.unicodeScalars.allSatisfy { hexChars.contains($0) })
    }

    func testAuraColorHexFormat() throws {
        let circleID = "test"
        let alice = HandshakeSession(circleID: circleID)
        let deadLink = try alice.initiate()
        let bob = HandshakeSession(circleID: circleID)
        let bobPK = try bob.respond(to: deadLink.toURI())
        try alice.receiveResponse(remotePublicKeyData: bobPK)

        let hex = alice.auraColorHex!
        XCTAssertTrue(hex.hasPrefix("#"))
        XCTAssertEqual(hex.count, 7)
    }

    // MARK: - Rejection

    func testRejectTransitionsToGhost() throws {
        let session = HandshakeSession()
        try session.initiate()
        session.reject()
        XCTAssertEqual(session.phase, .ghost)
    }

    // MARK: - Expiry

    func testExpireTransitionsToDeadLink() throws {
        let session = HandshakeSession()
        try session.initiate()
        session.expire()
        XCTAssertEqual(session.phase, .deadLink)
    }

    // MARK: - State Machine Guards

    func testConfirmFromIdleThrows() {
        let session = HandshakeSession()
        XCTAssertThrowsError(try session.confirm()) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.invalidStateTransition)
        }
    }

    func testReceiveResponseFromIdleThrows() {
        let session = HandshakeSession()
        XCTAssertThrowsError(try session.receiveResponse(remotePublicKeyData: Data(repeating: 0, count: 32))) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.invalidStateTransition)
        }
    }

    func testRespondTwiceThrows() throws {
        let alice = HandshakeSession(circleID: "test")
        let deadLink = try alice.initiate()
        let uri = deadLink.toURI()

        let bob = HandshakeSession(circleID: "test")
        _ = try bob.respond(to: uri)

        // Bob is now in verifying, can't respond again
        XCTAssertThrowsError(try bob.respond(to: uri)) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.invalidStateTransition)
        }
    }
}
