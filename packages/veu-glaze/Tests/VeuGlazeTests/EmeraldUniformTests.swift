// EmeraldUniformTests.swift — Veu Protocol: Emerald Shader Uniform Tests

import XCTest
@testable import VeuGlaze
import simd

final class EmeraldUniformTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultUniformsAreZero() {
        let u = EmeraldUniforms()
        XCTAssertEqual(u.phase, 0)
        XCTAssertEqual(u.time, 0)
        XCTAssertEqual(u.resolution, .zero)
        XCTAssertEqual(u.progress, 0)
    }

    // MARK: - Custom Init

    func testCustomInit() {
        let u = EmeraldUniforms(
            phase: 3,
            time: 42.5,
            resolution: SIMD2<Float>(1170, 2532),
            progress: 0.375
        )
        XCTAssertEqual(u.phase, 3)
        XCTAssertEqual(u.time, 42.5)
        XCTAssertEqual(u.resolution.x, 1170)
        XCTAssertEqual(u.resolution.y, 2532)
        XCTAssertEqual(u.progress, 0.375)
    }

    // MARK: - Phase Mapping

    func testPhaseRawValuesMatchShaderConstants() {
        // Phase 0 = IDLE
        XCTAssertEqual(EmeraldUniforms(phase: 0).phase, 0)
        // Phase 1 = INITIATING
        XCTAssertEqual(EmeraldUniforms(phase: 1).phase, 1)
        // Phase 2 = AWAITING
        XCTAssertEqual(EmeraldUniforms(phase: 2).phase, 2)
        // Phase 3 = VERIFYING
        XCTAssertEqual(EmeraldUniforms(phase: 3).phase, 3)
        // Phase 4 = CONFIRMED
        XCTAssertEqual(EmeraldUniforms(phase: 4).phase, 4)
        // Phase 5 = DEAD_LINK
        XCTAssertEqual(EmeraldUniforms(phase: 5).phase, 5)
        // Phase 6 = GHOST
        XCTAssertEqual(EmeraldUniforms(phase: 6).phase, 6)
    }

    // MARK: - Memory Layout

    func testEmeraldUniformsMemoryLayout() {
        let size = MemoryLayout<EmeraldUniforms>.size
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThanOrEqual(size, 48, "Unexpected uniform buffer bloat")
    }

    // MARK: - Shader Source

    func testEmeraldShaderSourceIsNonEmpty() {
        XCTAssertFalse(EmeraldShader.source.isEmpty)
    }

    func testEmeraldShaderContainsVertexFunction() {
        XCTAssertTrue(EmeraldShader.source.contains("fullscreenQuadVertex"))
    }

    func testEmeraldShaderContainsFragmentFunction() {
        XCTAssertTrue(EmeraldShader.source.contains("emeraldFragment"))
    }

    func testEmeraldShaderFunctionNames() {
        XCTAssertEqual(EmeraldShader.vertexFunction, "fullscreenQuadVertex")
        XCTAssertEqual(EmeraldShader.fragmentFunction, "emeraldFragment")
    }

    func testEmeraldShaderContainsAllPhases() {
        let source = EmeraldShader.source
        XCTAssertTrue(source.contains("phaseIdle"))
        XCTAssertTrue(source.contains("phaseInitiating"))
        XCTAssertTrue(source.contains("phaseAwaiting"))
        XCTAssertTrue(source.contains("phaseVerifying"))
        XCTAssertTrue(source.contains("phaseConfirmed"))
        XCTAssertTrue(source.contains("phaseDeadLink"))
        XCTAssertTrue(source.contains("phaseGhost"))
    }

    func testEmeraldShaderContainsEmeraldPalette() {
        let source = EmeraldShader.source
        XCTAssertTrue(source.contains("EMERALD"))
        XCTAssertTrue(source.contains("GHOST_WHITE"))
        XCTAssertTrue(source.contains("VOID_BLACK"))
        XCTAssertTrue(source.contains("WARN_RED"))
        XCTAssertTrue(source.contains("ASH_GREY"))
    }
}
