// AuraShader.swift — Metal translation of AURA.glsl
//
// The Aura shader renders an animated, reactive identity glow seeded by the
// user's Glaze Seed color.  This file contains the Metal Shading Language
// source as an embedded string and the uniform struct used to drive it.

import Foundation
import simd

/// Uniform buffer layout for the Aura shader.
///
/// Must match the `AuraUniforms` struct in the MSL source exactly.
public struct AuraUniforms {
    /// Elapsed time in seconds (drives animation).
    public var time: Float
    /// Viewport dimensions in pixels `(width, height)`.
    public var resolution: SIMD2<Float>
    /// RGB color derived from the user's Glaze Seed, each component in `[0, 1]`.
    public var seedColor: SIMD3<Float>
    /// Handshake/sync activity intensity `[0, 1]`.  0 = resting, 1 = flare.
    public var pulse: Float

    public init(time: Float = 0, resolution: SIMD2<Float> = .zero,
                seedColor: SIMD3<Float> = .zero, pulse: Float = 0) {
        self.time = time
        self.resolution = resolution
        self.seedColor = seedColor
        self.pulse = pulse
    }
}

/// Embedded Metal Shading Language source for the Aura identity shader.
///
/// Translated from `packages/veu-app/AURA.glsl`.
public enum AuraShader {

    /// The vertex function name in the compiled Metal library.
    public static let vertexFunction = "fullscreenQuadVertex"

    /// The fragment function name in the compiled Metal library.
    public static let fragmentFunction = "auraFragment"

    /// Complete MSL source (vertex + fragment).
    public static let source: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct AuraUniforms {
        float  time;
        float2 resolution;
        float3 seedColor;
        float  pulse;
    };

    // Fullscreen triangle (no vertex buffer needed)
    vertex VertexOut fullscreenQuadVertex(uint vid [[vertex_id]]) {
        VertexOut out;
        out.uv = float2((vid << 1) & 2, vid & 2);
        out.position = float4(out.uv * 2.0 - 1.0, 0.0, 1.0);
        out.uv.y = 1.0 - out.uv.y; // flip Y to match gl_FragCoord convention
        return out;
    }

    // --- Utility ---

    float aura_hash(float2 p) {
        p = fract(p * float2(127.1, 311.7));
        p += dot(p, p + 19.19);
        return fract(p.x * p.y);
    }

    float aura_valueNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

        float a = aura_hash(i);
        float b = aura_hash(i + float2(1.0, 0.0));
        float c = aura_hash(i + float2(0.0, 1.0));
        float d = aura_hash(i + float2(1.0, 1.0));

        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    float aura_fbm(float2 p) {
        float v     = 0.0;
        float amp   = 0.5;
        float freq  = 1.0;
        float total = 0.0;
        for (int i = 0; i < 5; i++) {
            v     += amp * aura_valueNoise(p * freq);
            total += amp;
            freq  *= 2.1;
            amp   *= 0.48;
        }
        return v / total;
    }

    float3 aura_iridescence(float3 baseColor, float edgeFactor, float t) {
        float angle = edgeFactor * 0.6 + sin(t * 0.7) * 0.15;
        float c = cos(angle);
        float s = sin(angle);

        float3x3 rot = float3x3(
            float3(0.299 + 0.701*c + 0.168*s, 0.587 - 0.587*c + 0.330*s, 0.114 - 0.114*c - 0.497*s),
            float3(0.299 - 0.299*c - 0.328*s, 0.587 + 0.413*c + 0.035*s, 0.114 - 0.114*c + 0.292*s),
            float3(0.299 - 0.300*c + 1.250*s, 0.587 - 0.588*c - 1.050*s, 0.114 + 0.886*c - 0.203*s)
        );
        return clamp(rot * baseColor, 0.0, 1.0);
    }

    // --- Fragment ---

    fragment float4 auraFragment(VertexOut in [[stage_in]],
                                  constant AuraUniforms &u [[buffer(0)]]) {
        float2 fragCoord = float2(in.uv.x * u.resolution.x, in.uv.y * u.resolution.y);
        float2 uv = (fragCoord * 2.0 - u.resolution) / min(u.resolution.x, u.resolution.y);
        float dist = length(uv);

        float t = u.time * 0.15;

        float2 q = float2(
            aura_fbm(uv + float2(0.0, t)),
            aura_fbm(uv + float2(1.7, t * 0.9))
        );

        float2 r = float2(
            aura_fbm(uv + 1.5 * q + float2(1.7, 9.2) + t * 0.12),
            aura_fbm(uv + 1.5 * q + float2(8.3, 2.8) + t * 0.11)
        );

        float noiseField = aura_fbm(uv + r);

        float pulseExpand = 1.0 + u.pulse * 0.35;
        float pulseBright = 1.0 + u.pulse * 0.5;

        float d = (dist - noiseField * 0.25) / pulseExpand;

        float glowVal = exp(-d * d * 2.8);
        float corona  = exp(-d * d * 0.6) * 0.35;
        float totalGlow = glowVal + corona;

        float3 coreColor = mix(u.seedColor, float3(1.0), 0.6);
        float3 edgeColor = u.seedColor * 0.4;

        float edgeFactor = clamp(d, 0.0, 1.0);
        float3 color = mix(coreColor, edgeColor, edgeFactor);

        float3 iriColor = aura_iridescence(color, edgeFactor, u.time);
        color = mix(color, iriColor, edgeFactor * 0.6);

        color *= totalGlow * pulseBright;

        float breathe = 0.85 + 0.15 * sin(u.time * 0.5);
        color *= breathe;

        float alpha = clamp(totalGlow * pulseBright * breathe, 0.0, 1.0);

        return float4(color, alpha);
    }
    """
}
