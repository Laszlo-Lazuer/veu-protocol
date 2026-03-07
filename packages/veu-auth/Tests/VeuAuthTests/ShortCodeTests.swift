// ShortCodeTests.swift — Tests for SAS short-code and Aura color derivation.

import XCTest
@testable import VeuAuth
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import VeuCrypto

final class ShortCodeTests: XCTestCase {

    // MARK: - Fixtures

    /// A deterministic Circle key for reproducible tests.
    private var sampleCircleKey: CircleKey {
        let keyData = Data(repeating: 0xAB, count: 32)
        let saltData = Data(repeating: 0xCD, count: 16)
        return CircleKey(keyData: keyData, glazeSalt: saltData)
    }

    // MARK: - 8-Digit Code

    func testDeriveCodeReturns8Characters() {
        let code = ShortCode.deriveCode(from: sampleCircleKey)
        XCTAssertEqual(code.count, 8)
    }

    func testDeriveCodeIsUppercaseHex() {
        let code = ShortCode.deriveCode(from: sampleCircleKey)
        let hexChars = CharacterSet(charactersIn: "0123456789ABCDEF")
        XCTAssertTrue(code.unicodeScalars.allSatisfy { hexChars.contains($0) })
    }

    func testDeriveCodeIsDeterministic() {
        let code1 = ShortCode.deriveCode(from: sampleCircleKey)
        let code2 = ShortCode.deriveCode(from: sampleCircleKey)
        XCTAssertEqual(code1, code2)
    }

    func testDifferentKeysProduceDifferentCodes() {
        let key1 = CircleKey(keyData: Data(repeating: 0x01, count: 32), glazeSalt: Data(repeating: 0x00, count: 16))
        let key2 = CircleKey(keyData: Data(repeating: 0x02, count: 32), glazeSalt: Data(repeating: 0x00, count: 16))

        let code1 = ShortCode.deriveCode(from: key1)
        let code2 = ShortCode.deriveCode(from: key2)
        XCTAssertNotEqual(code1, code2)
    }

    func testBothPeersGetSameCode() throws {
        let alice = EphemeralKeypair.generate()
        let bob = EphemeralKeypair.generate()
        let circleID = "test-circle"

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

        XCTAssertEqual(
            ShortCode.deriveCode(from: ckAlice),
            ShortCode.deriveCode(from: ckBob)
        )
    }

    // MARK: - Aura Color Hex

    func testDeriveAuraColorHexFormat() {
        let hex = ShortCode.deriveAuraColorHex(from: sampleCircleKey)
        XCTAssertTrue(hex.hasPrefix("#"))
        XCTAssertEqual(hex.count, 7) // "#RRGGBB"
    }

    func testDeriveAuraColorHexIsDeterministic() {
        let hex1 = ShortCode.deriveAuraColorHex(from: sampleCircleKey)
        let hex2 = ShortCode.deriveAuraColorHex(from: sampleCircleKey)
        XCTAssertEqual(hex1, hex2)
    }

    func testDifferentKeysProduceDifferentColors() {
        let key1 = CircleKey(keyData: Data(repeating: 0x01, count: 32), glazeSalt: Data(repeating: 0x00, count: 16))
        let key2 = CircleKey(keyData: Data(repeating: 0x02, count: 32), glazeSalt: Data(repeating: 0x00, count: 16))

        let hex1 = ShortCode.deriveAuraColorHex(from: key1)
        let hex2 = ShortCode.deriveAuraColorHex(from: key2)
        XCTAssertNotEqual(hex1, hex2)
    }

    // MARK: - Aura Color Float

    func testDeriveAuraColorInRange() {
        let color = ShortCode.deriveAuraColor(from: sampleCircleKey)
        XCTAssertGreaterThanOrEqual(color.r, 0.0)
        XCTAssertLessThanOrEqual(color.r, 1.0)
        XCTAssertGreaterThanOrEqual(color.g, 0.0)
        XCTAssertLessThanOrEqual(color.g, 1.0)
        XCTAssertGreaterThanOrEqual(color.b, 0.0)
        XCTAssertLessThanOrEqual(color.b, 1.0)
    }

    func testBothPeersGetSameAuraColor() throws {
        let alice = EphemeralKeypair.generate()
        let bob = EphemeralKeypair.generate()
        let circleID = "test-circle"

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

        XCTAssertEqual(
            ShortCode.deriveAuraColorHex(from: ckAlice),
            ShortCode.deriveAuraColorHex(from: ckBob)
        )
    }

    // MARK: - Verification

    func testVerifyMatchingCodesSucceeds() throws {
        let code = ShortCode.deriveCode(from: sampleCircleKey)
        XCTAssertNoThrow(try ShortCode.verify(localCode: code, remoteCode: code))
    }

    func testVerifyMismatchedCodesThrows() {
        XCTAssertThrowsError(try ShortCode.verify(localCode: "AABBCCDD", remoteCode: "11223344")) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.shortCodeMismatch)
        }
    }
}
