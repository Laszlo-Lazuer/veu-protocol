// AuraRenderer.swift — Veu Protocol: Aura Identity Shader Renderer
//
// Metal renderer that manages Aura-specific uniforms (seed color, pulse)
// and drives the AURA.metal shader each frame.

#if canImport(Metal) && canImport(MetalKit)
import Metal
import MetalKit
import simd

/// Metal renderer for the Aura identity shader.
///
/// Manages the `AuraUniforms` buffer and drives the AURA shader each frame.
/// Typically owned by `AuraView` and updated via its published properties.
public final class AuraRenderer: MetalRenderer {

    // MARK: - Uniform State

    /// The user's Glaze Seed color (RGB, each in `[0, 1]`).
    public var seedColor: SIMD3<Float> = SIMD3<Float>(0.314, 0.784, 0.471)

    /// Handshake/sync pulse intensity `[0, 1]`.
    public var pulse: Float = 0.0

    // MARK: - Init

    /// Create an AuraRenderer and compile the Aura shader pipeline.
    public override init(device: MTLDevice? = nil) throws {
        try super.init(device: device)
        try buildPipeline(
            source: AuraShader.source,
            vertexFunction: AuraShader.vertexFunction,
            fragmentFunction: AuraShader.fragmentFunction
        )
    }

    // MARK: - Draw

    public override func draw(in view: MTKView) {
        var uniforms = AuraUniforms(
            time: elapsedTime,
            resolution: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            seedColor: seedColor,
            pulse: pulse
        )
        drawFullscreenQuad(
            in: view,
            uniformBytes: &uniforms,
            uniformLength: MemoryLayout<AuraUniforms>.stride
        )
    }
}
#endif
