// BubbleShader.swift — Metal Shader for Animated Chat Bubbles
//
// A subtle, flowing gradient shader for chat message bubbles.  Uses FBM
// noise (like the Aura shader) but at lower intensity and slower speed
// to serve as a background texture rather than a focal element.
//
// Two modes: "sent" (emerald-tinted) and "received" (ghost-white).

import Foundation
import simd

/// Uniform buffer layout for the Bubble shader.
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

/// Embedded Metal Shading Language source for the Bubble shader.
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

    // Fullscreen triangle (no vertex buffer needed)
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
        for (int i = 0; i < 4; i++) {
            v     += amp * bubble_valueNoise(p * freq);
            total += amp;
            freq  *= 2.0;
            amp   *= 0.5;
        }
        return v / total;
    }

    // Rounded rectangle SDF
    float roundedRectSDF(float2 p, float2 size, float radius) {
        float2 d = abs(p) - size + radius;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
    }

    // --- Fragment ---

    fragment float4 bubbleFragment(VertexOut in [[stage_in]],
                                    constant BubbleUniforms &u [[buffer(0)]]) {
        float2 fragCoord = float2(in.uv.x * u.resolution.x, in.uv.y * u.resolution.y);
        float2 uv = fragCoord / u.resolution;

        // Slow time for subtle motion
        float t = u.time * 0.08;

        // Two-pass FBM for organic flow
        float2 q = float2(
            bubble_fbm(uv * 3.0 + float2(0.0, t)),
            bubble_fbm(uv * 3.0 + float2(1.7, t * 0.8))
        );

        float noise = bubble_fbm(uv * 2.5 + q * 0.4);

        // Color palettes
        // Sent: emerald gradient (dark → light)
        float3 sentDark  = float3(0.220, 0.580, 0.360);
        float3 sentLight = float3(0.340, 0.820, 0.500);

        // Received: ghost-white with subtle cool tones
        float3 recvDark  = float3(0.180, 0.185, 0.200);
        float3 recvLight = float3(0.240, 0.245, 0.260);

        float3 dark  = mix(recvDark,  sentDark,  u.isSent);
        float3 light = mix(recvLight, sentLight, u.isSent);

        // Blend noise into gradient
        float gradient = mix(0.35, 0.65, uv.y) + noise * 0.15;
        float3 color = mix(dark, light, gradient);

        // Subtle shimmer highlight
        float shimmer = bubble_fbm(uv * 6.0 + float2(t * 1.5, t * 0.6));
        float shimmerMask = smoothstep(0.55, 0.75, shimmer);
        float shimmerIntensity = mix(0.04, 0.08, u.isSent);
        color += shimmerIntensity * shimmerMask;

        // Rounded rectangle mask
        float2 center = fragCoord - u.resolution * 0.5;
        float2 halfSize = u.resolution * 0.5;
        float dist = roundedRectSDF(center, halfSize, u.cornerRadius);
        float alpha = 1.0 - smoothstep(-1.0, 0.5, dist);

        return float4(color * alpha, alpha);
    }
    """
}
