// BubbleView.swift — Veu Protocol: SwiftUI Animated Bubble Background
//
// SwiftUI wrapper for the Metal chat bubble shader.  Renders a subtly
// animated, flowing gradient that replaces flat color backgrounds.
// Battery-conscious at 30fps.

#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import MetalKit

/// SwiftUI view rendering an animated chat bubble background via Metal.
///
/// ```swift
/// BubbleView(isSent: true)
///     .frame(width: 200, height: 44)
/// ```
public struct BubbleView {
    /// Whether this is a sent message (emerald) or received (ghost-white).
    public var isSent: Bool

    /// Corner radius for the bubble shape.
    public var cornerRadius: Float

    public init(isSent: Bool = true, cornerRadius: Float = 18.0) {
        self.isSent = isSent
        self.cornerRadius = cornerRadius
    }
}

#if os(macOS)
extension BubbleView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 30
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.layer?.isOpaque = false

        if let renderer = try? BubbleRenderer() {
            renderer.isSent = isSent
            renderer.cornerRadius = cornerRadius
            mtkView.device = renderer.device
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.isSent = isSent
        context.coordinator.renderer?.cornerRadius = cornerRadius
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var renderer: BubbleRenderer?
    }
}
#else
extension BubbleView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 30
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.isOpaque = false

        if let renderer = try? BubbleRenderer() {
            renderer.isSent = isSent
            renderer.cornerRadius = cornerRadius
            mtkView.device = renderer.device
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return mtkView
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.isSent = isSent
        context.coordinator.renderer?.cornerRadius = cornerRadius
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var renderer: BubbleRenderer?
    }
}
#endif
#endif
