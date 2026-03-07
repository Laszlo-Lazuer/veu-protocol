// AuraUniformTests.swift — Veu Protocol: Aura Shader Uniform Tests

import XCTest
@testable import VeuGlaze
import simd

final class AuraUniformTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultUniformsAreZero() {
        let u = AuraUniforms()
        XCTAssertEqual(u.time, 0)
        XCTAssertEqual(u.resolution, .zero)
        XCTAssertEqual(u.seedColor, .zero)
        XCTAssertEqual(u.pulse, 0)
    }

    // MARK: - Custom Init

    func testCustomInit() {
        let u = AuraUniforms(
            time: 1.5,
            resolution: SIMD2<Float>(800, 600),
            seedColor: SIMD3<Float>(0.314, 0.784, 0.471),
            pulse: 0.75
        )
        XCTAssertEqual(u.time, 1.5)
        XCTAssertEqual(u.resolution.x, 800)
        XCTAssertEqual(u.resolution.y, 600)
        XCTAssertEqual(u.seedColor.x, 0.314, accuracy: 0.001)
        XCTAssertEqual(u.seedColor.y, 0.784, accuracy: 0.001)
        XCTAssertEqual(u.seedColor.z, 0.471, accuracy: 0.001)
        XCTAssertEqual(u.pulse, 0.75)
    }

    // MARK: - Memory Layout

    func testAuraUniformsMemoryLayout() {
        // Verify the struct packs properly for Metal buffer binding.
        // time(4) + pad(4) + resolution(8) + seedColor(12) + pad(4) + pulse(4) = at most 48
        // but the exact layout depends on SIMD alignment; just ensure it's reasonable.
        let size = MemoryLayout<AuraUniforms>.size
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThanOrEqual(size, 48, "Unexpected uniform buffer bloat")
    }

    // MARK: - Shader Source

    func testAuraShaderSourceIsNonEmpty() {
        XCTAssertFalse(AuraShader.source.isEmpty)
    }

    func testAuraShaderContainsVertexFunction() {
        XCTAssertTrue(AuraShader.source.contains("fullscreenQuadVertex"))
    }

    func testAuraShaderContainsFragmentFunction() {
        XCTAssertTrue(AuraShader.source.contains("auraFragment"))
    }

    func testAuraShaderFunctionNames() {
        XCTAssertEqual(AuraShader.vertexFunction, "fullscreenQuadVertex")
        XCTAssertEqual(AuraShader.fragmentFunction, "auraFragment")
    }

    func testAuraShaderContainsMetalHeaders() {
        XCTAssertTrue(AuraShader.source.contains("#include <metal_stdlib>"))
        XCTAssertTrue(AuraShader.source.contains("using namespace metal"))
    }

    func testAuraShaderContainsUniformStruct() {
        XCTAssertTrue(AuraShader.source.contains("AuraUniforms"))
        XCTAssertTrue(AuraShader.source.contains("seedColor"))
        XCTAssertTrue(AuraShader.source.contains("pulse"))
    }
}
