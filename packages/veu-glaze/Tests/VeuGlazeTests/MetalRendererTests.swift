// MetalRendererTests.swift — Veu Protocol: Metal Renderer Tests
//
// Tests MetalRenderer initialization and pipeline compilation.
// Gracefully skips when no Metal GPU device is available.

import XCTest
@testable import VeuGlaze

#if canImport(Metal)
import Metal

final class MetalRendererTests: XCTestCase {

    func testRendererCreation() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "No Metal device available")
        let renderer = try MetalRenderer()
        XCTAssertNotNil(renderer.device)
        XCTAssertNotNil(renderer.commandQueue)
    }

    func testAuraPipelineCompiles() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "No Metal device available")
        let renderer = try AuraRenderer()
        XCTAssertNotNil(renderer.pipelineState)
    }

    func testEmeraldPipelineCompiles() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "No Metal device available")
        let renderer = try EmeraldRenderer()
        XCTAssertNotNil(renderer.pipelineState)
    }

    func testElapsedTimeAdvances() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "No Metal device available")
        let renderer = try MetalRenderer()
        let t1 = renderer.elapsedTime
        Thread.sleep(forTimeInterval: 0.05)
        let t2 = renderer.elapsedTime
        XCTAssertGreaterThan(t2, t1)
    }

    func testBadShaderSourceThrows() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "No Metal device available")
        let renderer = try MetalRenderer()
        XCTAssertThrowsError(try renderer.buildPipeline(
            source: "this is not valid MSL",
            vertexFunction: "noVertex",
            fragmentFunction: "noFragment"
        ))
    }
}
#endif
