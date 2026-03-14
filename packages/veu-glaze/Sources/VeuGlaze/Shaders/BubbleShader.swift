// BubbleShader.swift — Metal Shader for Chat Bubble Vapor Glow
//
// Renders a soft, animated vapor glow around the outside edge of a chat
// bubble.  The bubble interior is left transparent so SwiftUI can render
// a clean solid-color background behind the text.  The glow is a subtle
// FBM-noise-modulated bloom that breathes slowly — like warm breath on
// cold glass.
//
// Two modes: "sent" (emerald vapor) and "received" (cool silver vapor).

import Foundation
import simd

/// Uniform buffer layout for the Bubble glow shader.
///
/// Must match the `BubbleUniforms` struct in the MSL source exactly.
public struct BubbleUniforms {
    /// Elapsed time in seconds (drives animation).
    public var time: Float
    /// Viewport dimensions in pixels `(width, height)`.
    public var resolution: SIMD2<Float>
    /// Whether this is a sent message (1.0) or received (0.0).
    public var isSent: Float
    /// Corner radius in pixels for the bubble mask.
    public var cornerRadius: Float

    public init(time: Float = 0, resolution: SIMD2<Float> = .zero,
                isSent: Float = 1.0, cornerRadius: Float = 18.0) {
        self.time = time
        self.resolution = resolution
        self.isSent = isSent
        self.cornerRadius = cornerRadius
    }
}

/// Embedded Metal Shading Language source for the Bubble glow shader.
public enum BubbleShader {

    /// The vertex function name in the compiled Metal library.
    public static let vertexFunction = "bubbleQuadVertex"

    /// The fragment function name in the compiled Metal library.
    public static let fragmentFunction = "bubbleFragment"

    /// Complete MSL source (vertex + fragment).
    public static let source: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct BubbleUniforms {
        float  time;
        float2 resolution;
        float  isSent;
        float  cornerRadius;
    };

    vertex VertexOut bubbleQuadVertex(uint vid [[vertex_id]]) {
        VertexOut out;
        out.uv = float2((vid << 1) & 2, vid & 2);
        out.position = float4(out.uv * 2.0 - 1.0, 0.0, 1.0);
        out.uv.y = 1.0 - out.uv.y;
        return out;
    }

    // --- Noise ---

    float bubble_hash(float2 p) {
        p = fract(p * float2(127.1, 311.7));
        p += dot(p, p + 19.19);
        return fract(p.x * p.y);
    }

    float bubble_valueNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);

        float a = bubble_hash(i);
        float b = bubble_hash(i + float2(1.0, 0.0));
        float c = bubble_hash(i + float2(0.0, 1.0));
        float d = bubble_hash(i + float2(1.0, 1.0));

        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    float bubble_fbm(float2 p) {
        float v     = 0.0;
        float amp   = 0.5;
        float freq  = 1.0;
        float total = 0.0;
        for (int i = 0; i < 3; i++) {
            v     += amp * bubble_valueNoise(p * freq);
            total += amp;
            freq  *= 2.0;
            amp   *= 0.5;
        }
        return v / total;
    }

    // Rounded rectangle signed distance field
    float roundedRectSDF(float2 p, float2 size, float radius) {
        float2 d = abs(p) - size + radius;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
    }

    // --- Fragment ---

    fragment float4 bubbleFragment(VertexOut in [[stage_in]],
                                    constant BubbleUniforms &u [[buffer(0)]]) {
        float2 fragCoord = float2(in.uv.x * u.resolution.x, in.uv.y * u.resolution.y);
        float2 center = fragCoord - u.resolution * 0.5;
        float2 halfSize = u.resolution * 0.5;

        // Signed distance from rounded rect edge (negative = inside, positive = outside)
        float dist = roundedRectSDF(center, halfSize, u.cornerRadius);

        // Only render the glow halo (outside the bubble)
        // Pixels inside the bubble are fully transparent.
        if (dist < -0.5) {
            return float4(0.0);
        }

        float t = u.time * 0.1;

        // Normalized position for noise sampling
        float2 uv = fragCoord / u.resolution;

        // Animate noise along the bubble edge
        float edgeNoise = bubble_fbm(uv * 4.0 + float2(t, t * 0.7));

        // Breathing intensity
        float breathe = 0.7 + 0.3 * sin(u.time * 0.4);

        // Glow falloff: exponential decay from edge outward
        // glowWidth controls how far the vapor extends (in pixels)
        float glowWidth = 12.0 + edgeNoise * 6.0;
        float glow = exp(-dist * dist / (glowWidth * glowWidth)) * breathe;

        // Sent: emerald vapor
        float3 sentColor = float3(0.314, 0.784, 0.471);
        // Received: cool silver
        float3 recvColor = float3(0.65, 0.68, 0.72);

        float3 glowColor = mix(recvColor, sentColor, u.isSent);

        // Subtle color variation along edge
        float hueShift = edgeNoise * 0.15;
        glowColor = glowColor + hueShift * float3(-0.05, 0.08, -0.03);

        float alpha = glow * mix(0.25, 0.4, u.isSent);

        return float4(glowColor * alpha, alpha);
    }
    """
}
