import XCTest
@testable import VeuCrypto

final class GlazeSeedTests: XCTestCase {

    private let sampleCiphertext = Data("some encrypted bytes".utf8)
    private let sampleSalt       = Data(repeating: 0xAB, count: 16)

    // MARK: - Determinism

    func testSameCiphertextAndSaltProduceSameSeed() {
        let seed1 = GlazeSeed.glazeSeed(from: sampleCiphertext, salt: sampleSalt)
        let seed2 = GlazeSeed.glazeSeed(from: sampleCiphertext, salt: sampleSalt)
        XCTAssertEqual(seed1, seed2)
    }

    // MARK: - Salt variation

    func testDifferentSaltsProduceDifferentSeeds() {
        let salt1 = Data(repeating: 0x11, count: 16)
        let salt2 = Data(repeating: 0x22, count: 16)

        let seed1 = GlazeSeed.glazeSeed(from: sampleCiphertext, salt: salt1)
        let seed2 = GlazeSeed.glazeSeed(from: sampleCiphertext, salt: salt2)

        XCTAssertNotEqual(seed1, seed2)
    }

    func testDifferentCiphertextsProduceDifferentSeeds() {
        let ct1 = Data("ciphertext one".utf8)
        let ct2 = Data("ciphertext two".utf8)

        let seed1 = GlazeSeed.glazeSeed(from: ct1, salt: sampleSalt)
        let seed2 = GlazeSeed.glazeSeed(from: ct2, salt: sampleSalt)

        XCTAssertNotEqual(seed1, seed2)
    }

    // MARK: - Output length

    func testSeedIsAlways32Bytes() {
        let seed = GlazeSeed.glazeSeed(from: sampleCiphertext, salt: sampleSalt)
        XCTAssertEqual(seed.count, 32)
    }

    // MARK: - Glaze color

    func testGlazeColorChannelsAreNormalized() {
        let seed = GlazeSeed.glazeSeed(from: sampleCiphertext, salt: sampleSalt)
        let (r, g, b) = GlazeSeed.glazeColor(from: seed)

        XCTAssertGreaterThanOrEqual(r, 0.0)
        XCTAssertLessThanOrEqual(r, 1.0)
        XCTAssertGreaterThanOrEqual(g, 0.0)
        XCTAssertLessThanOrEqual(g, 1.0)
        XCTAssertGreaterThanOrEqual(b, 0.0)
        XCTAssertLessThanOrEqual(b, 1.0)
    }

    func testGlazeColorIsDeterministic() {
        let seed   = GlazeSeed.glazeSeed(from: sampleCiphertext, salt: sampleSalt)
        let color1 = GlazeSeed.glazeColor(from: seed)
        let color2 = GlazeSeed.glazeColor(from: seed)

        XCTAssertEqual(color1.r, color2.r)
        XCTAssertEqual(color1.g, color2.g)
        XCTAssertEqual(color1.b, color2.b)
    }

    func testGlazeColorFallbackOnShortSeed() {
        let (r, g, b) = GlazeSeed.glazeColor(from: Data())
        XCTAssertEqual(r, 0.0)
        XCTAssertEqual(g, 0.0)
        XCTAssertEqual(b, 0.0)
    }
}
