// EmeraldHandshakeTests.swift — Tests for X25519 ECDH and Circle key derivation.

import XCTest
@testable import VeuAuth
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import VeuCrypto

final class EmeraldHandshakeTests: XCTestCase {

    // MARK: - Keypair Generation

    func testEphemeralKeypairGeneratesUniqueKeys() {
        let kp1 = EphemeralKeypair.generate()
        let kp2 = EphemeralKeypair.generate()
        XCTAssertNotEqual(
            kp1.publicKey.rawRepresentation,
            kp2.publicKey.rawRepresentation
        )
    }

    func testEphemeralKeypairPublicKeyIs32Bytes() {
        let kp = EphemeralKeypair.generate()
        XCTAssertEqual(kp.publicKey.rawRepresentation.count, 32)
    }

    // MARK: - Shared Secret

    func testSharedSecretIsSymmetric() throws {
        let alice = EphemeralKeypair.generate()
        let bob = EphemeralKeypair.generate()

        let ssAlice = try EmeraldHandshake.sharedSecret(
            localPrivateKey: alice.privateKey,
            remotePublicKey: bob.publicKey
        )
        let ssBob = try EmeraldHandshake.sharedSecret(
            localPrivateKey: bob.privateKey,
            remotePublicKey: alice.publicKey
        )

        // Both sides derive the same shared secret
        let dataAlice = ssAlice.withUnsafeBytes { Data($0) }
        let dataBob = ssBob.withUnsafeBytes { Data($0) }
        XCTAssertEqual(dataAlice, dataBob)
    }

    func testDifferentPeersProduceDifferentSecrets() throws {
        let alice = EphemeralKeypair.generate()
        let bob = EphemeralKeypair.generate()
        let charlie = EphemeralKeypair.generate()

        let ssAB = try EmeraldHandshake.sharedSecret(
            localPrivateKey: alice.privateKey,
            remotePublicKey: bob.publicKey
        )
        let ssAC = try EmeraldHandshake.sharedSecret(
            localPrivateKey: alice.privateKey,
            remotePublicKey: charlie.publicKey
        )

        let dataAB = ssAB.withUnsafeBytes { Data($0) }
        let dataAC = ssAC.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(dataAB, dataAC)
    }

    // MARK: - Circle Key Derivation

    func testDeriveCircleKeyProduces256BitKey() throws {
        let alice = EphemeralKeypair.generate()
        let bob = EphemeralKeypair.generate()

        let ss = try EmeraldHandshake.sharedSecret(
            localPrivateKey: alice.privateKey,
            remotePublicKey: bob.publicKey
        )
        let circleKey = try EmeraldHandshake.deriveCircleKey(from: ss, circleID: "test-circle")

        // CircleKey symmetric key should be 256-bit (32 bytes)
        let keyData = circleKey.symmetricKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(keyData.count, 32)
    }

    func testDeriveCircleKeyProduces128BitGlazeSalt() throws {
        let alice = EphemeralKeypair.generate()
        let bob = EphemeralKeypair.generate()

        let ss = try EmeraldHandshake.sharedSecret(
            localPrivateKey: alice.privateKey,
            remotePublicKey: bob.publicKey
        )
        let circleKey = try EmeraldHandshake.deriveCircleKey(from: ss, circleID: "test-circle")

        // Glaze salt should be 128-bit (16 bytes)
        XCTAssertEqual(circleKey.glazeSalt.count, 16)
    }

    func testBothPeersDeriveIdenticalCircleKey() throws {
        let alice = EphemeralKeypair.generate()
        let bob = EphemeralKeypair.generate()
        let circleID = "shared-circle"

        let ckAlice = try EmeraldHandshake.performKeyExchange(
            localPrivateKey: alice.privateKey,
            remotePublicKey: bob.publicKey,
            circleID: circleID
        )
        let ckBob = try EmeraldHandshake.performKeyExchange(
            localPrivateKey: bob.privateKey,
            remotePublicKey: alice.publicKey,
            circleID: circleID
        )

        let keyAlice = ckAlice.symmetricKey.withUnsafeBytes { Data($0) }
        let keyBob = ckBob.symmetricKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(keyAlice, keyBob)

        XCTAssertEqual(ckAlice.glazeSalt, ckBob.glazeSalt)
    }

    func testDifferentCircleIDsProduceDifferentKeys() throws {
        let alice = EphemeralKeypair.generate()
        let bob = EphemeralKeypair.generate()

        let ck1 = try EmeraldHandshake.performKeyExchange(
            localPrivateKey: alice.privateKey,
            remotePublicKey: bob.publicKey,
            circleID: "circle-A"
        )
        let ck2 = try EmeraldHandshake.performKeyExchange(
            localPrivateKey: alice.privateKey,
            remotePublicKey: bob.publicKey,
            circleID: "circle-B"
        )

        let key1 = ck1.symmetricKey.withUnsafeBytes { Data($0) }
        let key2 = ck2.symmetricKey.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(key1, key2)
    }

    // MARK: - Phase Enum

    func testHandshakePhaseHasSevenCases() {
        XCTAssertEqual(HandshakePhase.allCases.count, 7)
    }

    func testHandshakePhaseRawValues() {
        XCTAssertEqual(HandshakePhase.idle.rawValue, 0)
        XCTAssertEqual(HandshakePhase.initiating.rawValue, 1)
        XCTAssertEqual(HandshakePhase.awaiting.rawValue, 2)
        XCTAssertEqual(HandshakePhase.verifying.rawValue, 3)
        XCTAssertEqual(HandshakePhase.confirmed.rawValue, 4)
        XCTAssertEqual(HandshakePhase.deadLink.rawValue, 5)
        XCTAssertEqual(HandshakePhase.ghost.rawValue, 6)
    }
}
