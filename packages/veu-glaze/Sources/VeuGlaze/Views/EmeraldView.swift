// EmeraldView.swift — Veu Protocol: SwiftUI Emerald Handshake View
//
// SwiftUI wrapper that loads the Emerald Handshake ceremony shader and
// drives it from the handshake phase and progress values.

#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import MetalKit
import VeuAuth

/// SwiftUI view rendering the Emerald Handshake ceremony shader.
///
/// The Emerald shader implements seven visual phases (IDLE through GHOST)
/// that map to the cryptographic state of the handshake.
///
/// ```swift
/// EmeraldView(phase: .verifying, progress: 0.375)  // 3 of 8 segments lit
/// ```
public struct EmeraldView {
    /// The current handshake ceremony phase.
    public var phase: HandshakePhase

    /// Progress within the current phase `[0, 1]`.
    public var progress: Float

    public init(phase: HandshakePhase = .idle, progress: Float = 0.0) {
        self.phase = phase
        self.progress = progress
    }
}

#if os(macOS)
extension EmeraldView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.layer?.isOpaque = false

        if let renderer = try? EmeraldRenderer() {
            renderer.phase = Int32(phase.rawValue)
            renderer.progress = progress
            mtkView.device = renderer.device
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.phase = Int32(phase.rawValue)
        context.coordinator.renderer?.progress = progress
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var renderer: EmeraldRenderer?
    }
}
#else
extension EmeraldView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.isOpaque = false

        if let renderer = try? EmeraldRenderer() {
            renderer.phase = Int32(phase.rawValue)
            renderer.progress = progress
            mtkView.device = renderer.device
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return mtkView
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.phase = Int32(phase.rawValue)
        context.coordinator.renderer?.progress = progress
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var renderer: EmeraldRenderer?
    }
}
#endif
#endif
