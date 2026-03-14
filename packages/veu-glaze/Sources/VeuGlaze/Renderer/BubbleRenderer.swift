// BubbleRenderer.swift — Veu Protocol: Chat Bubble Shader Renderer
//
// Metal renderer that drives the animated bubble background shader.
// Receives isSent flag to switch between emerald (sent) and ghost-white (received).

#if canImport(Metal) && canImport(MetalKit)
import Metal
import MetalKit
import simd

/// Metal renderer for the animated chat bubble shader.
public final class BubbleRenderer: MetalRenderer {

    // MARK: - Uniform State

    /// Whether this bubble is a sent message (true) or received (false).
    public var isSent: Bool = true

    /// Corner radius in points (will be scaled by content scale factor).
    public var cornerRadius: Float = 18.0

    // MARK: - Init

    /// Create a BubbleRenderer and compile the Bubble shader pipeline.
    public override init(device: MTLDevice? = nil) throws {
        try super.init(device: device)
        try buildPipeline(
            source: BubbleShader.source,
            vertexFunction: BubbleShader.vertexFunction,
            fragmentFunction: BubbleShader.fragmentFunction
        )
    }

    // MARK: - Draw

    public override func draw(in view: MTKView) {
        var uniforms = BubbleUniforms(
            time: elapsedTime,
            resolution: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            isSent: isSent ? 1.0 : 0.0,
            cornerRadius: cornerRadius * Float(view.drawableSize.width / max(view.bounds.width, 1))
        )
        drawFullscreenQuad(
            in: view,
            uniformBytes: &uniforms,
            uniformLength: MemoryLayout<BubbleUniforms>.stride
        )
    }
}
#endif
