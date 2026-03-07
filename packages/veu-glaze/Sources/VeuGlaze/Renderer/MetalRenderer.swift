// MetalRenderer.swift — Veu Protocol: Base Metal Rendering Pipeline
//
// Provides device initialization, shader compilation from embedded strings,
// pipeline state creation, and a fullscreen-quad draw helper.  Subclassed
// by AuraRenderer and EmeraldRenderer for shader-specific uniform management.

#if canImport(Metal) && canImport(MetalKit)
import Metal
import MetalKit
import simd

/// Base renderer that handles Metal device, command queue, and pipeline setup.
///
/// Both `AuraRenderer` and `EmeraldRenderer` inherit from this class and
/// override `draw(in:)` to supply their specific uniforms.
open class MetalRenderer: NSObject, MTKViewDelegate {

    // MARK: - Properties

    /// The Metal device (GPU).
    public let device: MTLDevice

    /// Command queue for encoding draw commands.
    public let commandQueue: MTLCommandQueue

    /// The compiled render pipeline state.
    public var pipelineState: MTLRenderPipelineState?

    /// The time at which rendering started (for u_time computation).
    public let startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    // MARK: - Init

    /// Create a renderer with an optional explicit Metal device.
    ///
    /// - Parameter device: A Metal device.  If `nil`, the system default is used.
    /// - Throws: `VeuGlazeError.metalDeviceUnavailable` if no GPU is available.
    public init(device: MTLDevice? = nil) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            throw VeuGlazeError.metalDeviceUnavailable
        }
        self.device = dev
        guard let queue = dev.makeCommandQueue() else {
            throw VeuGlazeError.renderError("Failed to create command queue")
        }
        self.commandQueue = queue
        super.init()
    }

    // MARK: - Pipeline

    /// Compile a render pipeline from the given MSL source string.
    ///
    /// - Parameters:
    ///   - source: Metal Shading Language source code.
    ///   - vertexFunction: Name of the vertex function in the source.
    ///   - fragmentFunction: Name of the fragment function in the source.
    ///   - pixelFormat: The output pixel format (default: `.bgra8Unorm`).
    /// - Throws: `VeuGlazeError.shaderCompilationFailed` or `.pipelineCreationFailed`.
    public func buildPipeline(
        source: String,
        vertexFunction: String,
        fragmentFunction: String,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws {
        let options = MTLCompileOptions()
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: options)
        } catch {
            throw VeuGlazeError.shaderCompilationFailed(error.localizedDescription)
        }

        guard let vertexFn = library.makeFunction(name: vertexFunction) else {
            throw VeuGlazeError.shaderCompilationFailed("Vertex function '\(vertexFunction)' not found")
        }
        guard let fragmentFn = library.makeFunction(name: fragmentFunction) else {
            throw VeuGlazeError.shaderCompilationFailed("Fragment function '\(fragmentFunction)' not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        // Enable alpha blending so the shader's alpha channel composites over the background.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw VeuGlazeError.pipelineCreationFailed(error.localizedDescription)
        }
    }

    // MARK: - Draw Helpers

    /// Encode a fullscreen triangle draw call with the given uniform buffer bytes.
    ///
    /// The fullscreen quad vertex function generates 3 vertices procedurally
    /// (no vertex buffer needed).
    public func drawFullscreenQuad(
        in view: MTKView,
        uniformBytes: UnsafeRawPointer,
        uniformLength: Int
    ) {
        guard let pipelineState = pipelineState,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.039, green: 0.039, blue: 0.039, alpha: 1.0)
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(uniformBytes, length: uniformLength, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Elapsed time since the renderer was created.
    public var elapsedTime: Float {
        Float(CFAbsoluteTimeGetCurrent() - startTime)
    }

    // MARK: - MTKViewDelegate

    open func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    open func draw(in view: MTKView) {}
}
#endif
