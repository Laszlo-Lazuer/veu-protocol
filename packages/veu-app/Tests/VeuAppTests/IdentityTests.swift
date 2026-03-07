import XCTest
@testable import VeuApp

final class IdentityTests: XCTestCase {

    func testGenerateProducesValidIdentity() {
        let id = Identity.generate()

        // Callsign is 8 uppercase hex chars
        XCTAssertEqual(id.callsign.count, 8)
        XCTAssertTrue(id.callsign.allSatisfy { $0.isHexDigit })

        // Device ID is 16 hex chars
        XCTAssertEqual(id.deviceID.count, 16)

        // Public key hex is 64 chars (32 bytes)
        XCTAssertEqual(id.publicKeyHex.count, 64)

        // Private key hex is 64 chars (32 bytes)
        XCTAssertEqual(id.privateKeyHex.count, 64)

        // Aura seed in [0, 1]
        XCTAssertTrue((0...1).contains(id.auraSeedR))
        XCTAssertTrue((0...1).contains(id.auraSeedG))
        XCTAssertTrue((0...1).contains(id.auraSeedB))
    }

    func testGenerateIsDeterministicForSameKey() {
        let id = Identity.generate()
        let pubData = Data(hexString: id.publicKeyHex)!

        // Derived values should be stable for the same public key
        let callsign = Identity.deriveCallsign(from: pubData)
        XCTAssertEqual(callsign, id.callsign)

        let aura = Identity.deriveAuraColor(from: pubData)
        XCTAssertEqual(aura.r, id.auraSeedR)
        XCTAssertEqual(aura.g, id.auraSeedG)
        XCTAssertEqual(aura.b, id.auraSeedB)

        let deviceID = Identity.deriveDeviceID(from: pubData)
        XCTAssertEqual(deviceID, id.deviceID)
    }

    func testTwoIdentitiesAreDifferent() {
        let a = Identity.generate()
        let b = Identity.generate()

        XCTAssertNotEqual(a.publicKeyHex, b.publicKeyHex)
        XCTAssertNotEqual(a.privateKeyHex, b.privateKeyHex)
        // Callsigns could theoretically collide, but it's astronomically unlikely
    }

    func testSigningKeyRoundTrip() throws {
        let id = Identity.generate()
        let privateKey = try id.signingPrivateKey
        let publicKey = try id.signingPublicKey

        // Sign and verify to confirm keys work
        let message = Data("test message".utf8)
        let signature = try privateKey.signature(for: message)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))
    }

    func testIdentityCodable() throws {
        let original = Identity.generate()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Identity.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testDataHexRoundTrip() {
        let original = Data([0x00, 0xAB, 0xCD, 0xEF, 0xFF])
        let hex = original.hexString
        XCTAssertEqual(hex, "00abcdefff")

        let restored = Data(hexString: hex)
        XCTAssertEqual(restored, original)
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(Data(hexString: "zz"))
        XCTAssertNil(Data(hexString: "abc")) // odd length
    }

    func testAuraSeedTuple() {
        let id = Identity.generate()
        let seed = id.auraSeed
        XCTAssertEqual(seed.r, id.auraSeedR)
        XCTAssertEqual(seed.g, id.auraSeedG)
        XCTAssertEqual(seed.b, id.auraSeedB)
    }
}
