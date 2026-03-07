// AuraView.swift — Veu Protocol: SwiftUI Aura Shader View
//
// SwiftUI wrapper that loads the Aura identity shader and feeds it the
// user's Glaze Seed color and pulse intensity from the app layer.

#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import MetalKit
import VeuCrypto

/// SwiftUI view rendering the Aura identity shader.
///
/// The Aura is an animated, reactive visual field unique to each user,
/// seeded by their Glaze Seed (HMAC-SHA-256 of their key hash).
///
/// ```swift
/// AuraView(seedColor: SIMD3<Float>(0.31, 0.78, 0.47), pulse: 0.0)
/// ```
public struct AuraView {
    /// RGB seed color, each component in `[0, 1]`.
    public var seedColor: SIMD3<Float>

    /// Pulse intensity `[0, 1]`.  0 = resting, 1 = handshake/sync flare.
    public var pulse: Float

    public init(seedColor: SIMD3<Float> = SIMD3<Float>(0.314, 0.784, 0.471),
                pulse: Float = 0.0) {
        self.seedColor = seedColor
        self.pulse = pulse
    }

    /// Convenience initializer from a 32-byte Glaze Seed `Data`.
    ///
    /// Extracts RGB from the first 3 bytes, normalized to `[0, 1]`.
    public init(glazeSeed: Data, pulse: Float = 0.0) {
        let color = GlazeSeed.glazeColor(from: glazeSeed)
        self.seedColor = SIMD3<Float>(color.r, color.g, color.b)
        self.pulse = pulse
    }
}

#if os(macOS)
extension AuraView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.layer?.isOpaque = false

        if let renderer = try? AuraRenderer() {
            renderer.seedColor = seedColor
            renderer.pulse = pulse
            mtkView.device = renderer.device
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.seedColor = seedColor
        context.coordinator.renderer?.pulse = pulse
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var renderer: AuraRenderer?
    }
}
#else
extension AuraView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.isOpaque = false

        if let renderer = try? AuraRenderer() {
            renderer.seedColor = seedColor
            renderer.pulse = pulse
            mtkView.device = renderer.device
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return mtkView
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.seedColor = seedColor
        context.coordinator.renderer?.pulse = pulse
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var renderer: AuraRenderer?
    }
}
#endif
#endif
