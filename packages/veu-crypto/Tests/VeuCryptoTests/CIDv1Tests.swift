// CIDv1Tests.swift — Veu Protocol: CIDv1 Content Identifier Tests

import XCTest
@testable import VeuCrypto

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class CIDv1Tests: XCTestCase {

    // MARK: - Generation

    func testGenerateProducesDeterministicCID() {
        let data = Data("hello world".utf8)
        let cid1 = CIDv1.generate(from: data)
        let cid2 = CIDv1.generate(from: data)
        XCTAssertEqual(cid1, cid2, "Same data must produce same CID")
    }

    func testGenerateStartsWithMultibasePrefix() {
        let cid = CIDv1.generate(from: Data("test".utf8))
        XCTAssertTrue(cid.hasPrefix("b"), "CIDv1 must start with base32lower prefix 'b'")
    }

    func testGenerateDifferentDataProducesDifferentCIDs() {
        let cid1 = CIDv1.generate(from: Data("alice".utf8))
        let cid2 = CIDv1.generate(from: Data("bob".utf8))
        XCTAssertNotEqual(cid1, cid2)
    }

    func testGenerateFromDigest() {
        let data = Data("hello world".utf8)
        let digest = Data(SHA256.hash(data: data))
        let cidFromData = CIDv1.generate(from: data)
        let cidFromDigest = CIDv1.generate(fromDigest: digest)
        XCTAssertEqual(cidFromData, cidFromDigest, "Generate from data and from digest must match")
    }

    func testGenerateEmptyData() {
        let cid = CIDv1.generate(from: Data())
        XCTAssertTrue(cid.hasPrefix("b"))
        XCTAssertTrue(CIDv1.isValid(cid))
    }

    func testGenerateLargeData() {
        let data = Data(repeating: 0xFF, count: 1_000_000)
        let cid = CIDv1.generate(from: data)
        XCTAssertTrue(CIDv1.isValid(cid))
    }

    // MARK: - Validation

    func testIsValidAcceptsGeneratedCID() {
        let cid = CIDv1.generate(from: Data("test artifact".utf8))
        XCTAssertTrue(CIDv1.isValid(cid))
    }

    func testIsValidRejectsEmptyString() {
        XCTAssertFalse(CIDv1.isValid(""))
    }

    func testIsValidRejectsShortString() {
        XCTAssertFalse(CIDv1.isValid("bafk"))
    }

    func testIsValidRejectsGarbage() {
        XCTAssertFalse(CIDv1.isValid("not-a-cid-at-all"))
    }

    func testIsValidRejectsWrongPrefix() {
        let cid = CIDv1.generate(from: Data("test".utf8))
        let noPrefixCID = "z" + String(cid.dropFirst())
        XCTAssertFalse(CIDv1.isValid(noPrefixCID))
    }

    func testIsValidRejectsTruncatedCID() {
        let cid = CIDv1.generate(from: Data("test".utf8))
        let truncated = String(cid.prefix(cid.count / 2))
        XCTAssertFalse(CIDv1.isValid(truncated))
    }

    // MARK: - Digest Extraction

    func testExtractDigestRoundTrips() {
        let data = Data("round trip test".utf8)
        let expectedDigest = Data(SHA256.hash(data: data))
        let cid = CIDv1.generate(from: data)
        let extracted = CIDv1.extractDigest(from: cid)
        XCTAssertEqual(extracted, expectedDigest)
    }

    func testExtractDigestReturnsNilForInvalidCID() {
        XCTAssertNil(CIDv1.extractDigest(from: "invalid"))
        XCTAssertNil(CIDv1.extractDigest(from: ""))
    }

    // MARK: - Known Vector

    func testKnownVector() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let cid = CIDv1.generate(from: Data())
        // Just verify it's deterministic and valid
        XCTAssertTrue(CIDv1.isValid(cid))
        let digest = CIDv1.extractDigest(from: cid)
        XCTAssertNotNil(digest)
        XCTAssertEqual(digest?.count, 32)
        // Verify the digest matches known SHA-256 of empty data
        let expectedHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let actualHex = digest!.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actualHex, expectedHex)
    }

    // MARK: - Base32 Encoding Consistency

    func testCIDContainsOnlyBase32Chars() {
        let cid = CIDv1.generate(from: Data("check charset".utf8))
        let body = String(cid.dropFirst()) // strip 'b' prefix
        let validChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")
        XCTAssertTrue(body.unicodeScalars.allSatisfy { validChars.contains($0) },
                      "CID body must only contain base32lower characters")
    }
}
