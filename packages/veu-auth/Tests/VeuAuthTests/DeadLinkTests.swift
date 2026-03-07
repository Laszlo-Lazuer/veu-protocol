// DeadLinkTests.swift — Tests for Dead Link URI generation, parsing, and validation.

import XCTest
@testable import VeuAuth
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class DeadLinkTests: XCTestCase {

    // MARK: - Fixtures

    private let keyAgreementKey = Curve25519.KeyAgreement.PrivateKey()
    private let signingKey = Curve25519.Signing.PrivateKey()

    // MARK: - Generation

    func testGenerateProducesValidURI() throws {
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey
        )

        let uri = link.toURI()
        XCTAssertTrue(uri.hasPrefix("veu://handshake?"))
        XCTAssertTrue(uri.contains("id="))
        XCTAssertTrue(uri.contains("pk="))
        XCTAssertTrue(uri.contains("exp="))
        XCTAssertTrue(uri.contains("sig="))
    }

    func testGenerateDefaultTTL() throws {
        let before = Int(Date().timeIntervalSince1970)
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey
        )
        let after = Int(Date().timeIntervalSince1970)

        // Expiry should be ~300 seconds (5 min) from now
        XCTAssertGreaterThanOrEqual(link.expiry, before + 300)
        XCTAssertLessThanOrEqual(link.expiry, after + 300)
    }

    func testGenerateCustomTTL() throws {
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey,
            ttl: 60
        )
        let now = Int(Date().timeIntervalSince1970)
        XCTAssertLessThanOrEqual(link.expiry, now + 61)
        XCTAssertGreaterThanOrEqual(link.expiry, now + 59)
    }

    // MARK: - Round-Trip (Generate → URI → Parse)

    func testRoundTrip() throws {
        let original = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey
        )

        let uri = original.toURI()
        let parsed = try DeadLink.parse(uri: uri)

        XCTAssertEqual(parsed.id, original.id)
        XCTAssertEqual(parsed.publicKey.rawRepresentation, original.publicKey.rawRepresentation)
        XCTAssertEqual(parsed.expiry, original.expiry)
        XCTAssertEqual(parsed.signature, original.signature)
    }

    // MARK: - Parsing Errors

    func testParseInvalidSchemeThrows() {
        XCTAssertThrowsError(try DeadLink.parse(uri: "https://handshake?id=abc")) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.deadLinkInvalid)
        }
    }

    func testParseMissingFieldsThrows() {
        XCTAssertThrowsError(try DeadLink.parse(uri: "veu://handshake?id=abc")) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.deadLinkInvalid)
        }
    }

    func testParseGarbageThrows() {
        XCTAssertThrowsError(try DeadLink.parse(uri: "not a uri at all")) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.deadLinkInvalid)
        }
    }

    // MARK: - Expiry

    func testIsExpiredReturnsFalseForFreshLink() throws {
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey
        )
        XCTAssertFalse(link.isExpired())
    }

    func testIsExpiredReturnsTrueForPastLink() throws {
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey,
            ttl: -10  // Already expired
        )
        XCTAssertTrue(link.isExpired())
    }

    // MARK: - Signature Verification

    func testVerifySucceedsWithCorrectKey() throws {
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey
        )
        XCTAssertNoThrow(try link.verify(signingPublicKey: signingKey.publicKey))
    }

    func testVerifyFailsWithWrongKey() throws {
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey
        )
        let wrongKey = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try link.verify(signingPublicKey: wrongKey.publicKey)) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.signatureInvalid)
        }
    }

    // MARK: - Full Validation

    func testValidateSucceeds() throws {
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey
        )
        XCTAssertNoThrow(try link.validate(signingPublicKey: signingKey.publicKey))
    }

    func testValidateFailsOnExpiry() throws {
        let link = try DeadLink.generate(
            keyAgreementPublicKey: keyAgreementKey.publicKey,
            signingKey: signingKey,
            ttl: -10
        )
        XCTAssertThrowsError(try link.validate(signingPublicKey: signingKey.publicKey)) { error in
            XCTAssertEqual(error as? VeuAuthError, VeuAuthError.deadLinkExpired)
        }
    }

    // MARK: - Base64URL Encoding

    func testBase64URLRoundTrip() {
        let original = Data([0x00, 0xFF, 0x3E, 0x3F, 0xFB, 0xFC])
        let encoded = original.base64URLEncoded()
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        let decoded = Data(base64URLEncoded: encoded)
        XCTAssertEqual(decoded, original)
    }
}
