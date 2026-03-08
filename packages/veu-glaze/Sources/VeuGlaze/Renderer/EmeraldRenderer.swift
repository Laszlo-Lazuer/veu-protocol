// EmeraldRenderer.swift — Veu Protocol: Emerald Handshake Shader Renderer
//
// Metal renderer that manages Emerald-specific uniforms (phase, progress)
// and drives the EMERALD.metal shader each frame.

#if canImport(Metal) && canImport(MetalKit)
import Metal
import MetalKit
import simd

/// Metal renderer for the Emerald Handshake ceremony shader.
///
/// Manages the `EmeraldUniforms` buffer and drives the EMERALD shader each
/// frame.  The `phase` and `progress` properties should be updated from the
/// handshake state machine in the app layer.
public final class EmeraldRenderer: MetalRenderer {

    // MARK: - Uniform State

    /// Current ceremony phase (0–6).
    public var phase: Int32 = 0

    /// Progress within the current phase `[0, 1]`.
    public var progress: Float = 0.0

    // MARK: - Init

    /// Create an EmeraldRenderer and compile the Emerald shader pipeline.
    public override init(device: MTLDevice? = nil) throws {
        try super.init(device: device)
        try buildPipeline(
            source: EmeraldShader.source,
            vertexFunction: EmeraldShader.vertexFunction,
            fragmentFunction: EmeraldShader.fragmentFunction
        )
    }

    // MARK: - Draw

    public override func draw(in view: MTKView) {
        var uniforms = EmeraldUniforms(
            phase: phase,
            time: elapsedTime,
            resolution: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            progress: progress
        )
        drawFullscreenQuad(
            in: view,
            uniformBytes: &uniforms,
            uniformLength: MemoryLayout<EmeraldUniforms>.stride
        )
    }
}
#endif
