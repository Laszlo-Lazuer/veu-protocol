// ColorDerivationTests.swift — Veu Protocol: Glaze Seed → RGB Mapping Tests

import XCTest
@testable import VeuGlaze
import VeuCrypto
import simd

final class ColorDerivationTests: XCTestCase {

    // MARK: - GlazeSeed → Color

    func testGlazeColorFromKnownSeed() {
        // Construct a deterministic seed
        let seed = Data([80, 200, 120] + Array(repeating: UInt8(0), count: 29))
        let color = GlazeSeed.glazeColor(from: seed)

        XCTAssertEqual(color.r, Float(80) / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.g, Float(200) / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.b, Float(120) / 255.0, accuracy: 0.001)
    }

    func testGlazeColorComponentsAreNormalized() {
        let seed = Data([255, 0, 128] + Array(repeating: UInt8(0), count: 29))
        let color = GlazeSeed.glazeColor(from: seed)

        XCTAssertGreaterThanOrEqual(color.r, 0.0)
        XCTAssertLessThanOrEqual(color.r, 1.0)
        XCTAssertGreaterThanOrEqual(color.g, 0.0)
        XCTAssertLessThanOrEqual(color.g, 1.0)
        XCTAssertGreaterThanOrEqual(color.b, 0.0)
        XCTAssertLessThanOrEqual(color.b, 1.0)
    }

    func testGlazeColorFromShortSeedReturnsBlack() {
        let short = Data([42, 99])
        let color = GlazeSeed.glazeColor(from: short)
        XCTAssertEqual(color.r, 0)
        XCTAssertEqual(color.g, 0)
        XCTAssertEqual(color.b, 0)
    }

    // MARK: - SIMD Conversion

    func testGlazeColorToSIMD3() {
        let seed = Data([80, 200, 120] + Array(repeating: UInt8(0), count: 29))
        let color = GlazeSeed.glazeColor(from: seed)
        let simd = SIMD3<Float>(color.r, color.g, color.b)

        XCTAssertEqual(simd.x, color.r)
        XCTAssertEqual(simd.y, color.g)
        XCTAssertEqual(simd.z, color.b)
    }

    // MARK: - Determinism

    func testGlazeSeedIsDeterministic() {
        let ciphertext = Data("hello world".utf8)
        let salt = Data(repeating: 0xAA, count: 16)

        let seed1 = GlazeSeed.glazeSeed(from: ciphertext, salt: salt)
        let seed2 = GlazeSeed.glazeSeed(from: ciphertext, salt: salt)

        XCTAssertEqual(seed1, seed2)
        XCTAssertEqual(seed1.count, 32)
    }

    func testDifferentCiphertextProducesDifferentSeed() {
        let salt = Data(repeating: 0xBB, count: 16)
        let seed1 = GlazeSeed.glazeSeed(from: Data("alpha".utf8), salt: salt)
        let seed2 = GlazeSeed.glazeSeed(from: Data("bravo".utf8), salt: salt)

        XCTAssertNotEqual(seed1, seed2)
    }

    func testDifferentSaltProducesDifferentSeed() {
        let ciphertext = Data("same text".utf8)
        let seed1 = GlazeSeed.glazeSeed(from: ciphertext, salt: Data(repeating: 0x11, count: 16))
        let seed2 = GlazeSeed.glazeSeed(from: ciphertext, salt: Data(repeating: 0x22, count: 16))

        XCTAssertNotEqual(seed1, seed2)
    }
}
