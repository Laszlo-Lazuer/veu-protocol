// EmeraldShader.swift — Metal translation of EMERALD.glsl
//
// The Emerald shader implements the seven visual phases of the Emerald Handshake
// ceremony.  This file contains the Metal Shading Language source as an embedded
// string and the uniform struct used to drive it.

import Foundation
import simd

/// Uniform buffer layout for the Emerald Handshake shader.
///
/// Must match the `EmeraldUniforms` struct in the MSL source exactly.
public struct EmeraldUniforms {
    /// Current ceremony phase (0–6, see `HandshakePhase`).
    public var phase: Int32
    /// Elapsed time in seconds (continuous, never reset per phase).
    public var time: Float
    /// Viewport dimensions in pixels `(width, height)`.
    public var resolution: SIMD2<Float>
    /// Progress within the current phase `[0, 1]`.
    public var progress: Float

    public init(phase: Int32 = 0, time: Float = 0,
                resolution: SIMD2<Float> = .zero, progress: Float = 0) {
        self.phase = phase
        self.time = time
        self.resolution = resolution
        self.progress = progress
    }
}

/// Embedded Metal Shading Language source for the Emerald Handshake ceremony.
///
/// Translated from `packages/veu-app/EMERALD.glsl`.
public enum EmeraldShader {

    /// The vertex function name (standalone vertex function included in source).
    public static let vertexFunction = "fullscreenQuadVertex"

    /// The fragment function name in the compiled Metal library.
    public static let fragmentFunction = "emeraldFragment"

    /// Complete MSL source (vertex + fragment, fully standalone).
    public static let source: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Fullscreen triangle (no vertex buffer needed)
    vertex VertexOut fullscreenQuadVertex(uint vid [[vertex_id]]) {
        VertexOut out;
        out.uv = float2((vid << 1) & 2, vid & 2);
        out.position = float4(out.uv * 2.0 - 1.0, 0.0, 1.0);
        out.uv.y = 1.0 - out.uv.y;
        return out;
    }

    struct EmeraldUniforms {
        int    phase;
        float  time;
        float2 resolution;
        float  progress;
    };

    // Palette
    constant float3 EMERALD     = float3(0.314, 0.784, 0.471);
    constant float3 GHOST_WHITE = float3(0.973, 0.973, 1.000);
    constant float3 VOID_BLACK  = float3(0.039, 0.039, 0.039);
    constant float3 WARN_RED    = float3(0.784, 0.251, 0.251);
    constant float3 ASH_GREY    = float3(0.533, 0.533, 0.533);

    constant float EM_PI  = 3.14159265359;
    constant float EM_TAU = 6.28318530718;

    // --- Utility ---

    float em_hash(float2 p) {
        p = fract(p * float2(127.1, 311.7));
        p += dot(p, p + 19.19);
        return fract(p.x * p.y);
    }

    float em_hash1(float n) { return fract(sin(n) * 43758.5453); }

    float em_noise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(
            mix(em_hash(i),                 em_hash(i + float2(1.0, 0.0)), u.x),
            mix(em_hash(i + float2(0.0, 1.0)), em_hash(i + float2(1.0, 1.0)), u.x),
            u.y);
    }

    float em_ss(float a, float b, float t) { return smoothstep(a, b, t); }

    float em_ring(float dist, float radius, float thickness, float aa) {
        float d = abs(dist - radius) - thickness * 0.5;
        return 1.0 - em_ss(0.0, aa, d);
    }

    float em_disc(float dist, float radius, float aa) {
        return 1.0 - em_ss(radius - aa, radius + aa, dist);
    }

    float em_glow(float dist, float radius, float falloff) {
        float d = max(0.0, dist - radius);
        return exp(-d * falloff);
    }

    // --- Phase sub-routines ---

    float4 phaseIdle(float2 uv, float t) {
        float3 col = VOID_BLACK;
        float particles = 0.0;
        for (int i = 0; i < 24; i++) {
            float fi = float(i);
            float2 seed = float2(em_hash1(fi * 1.3), em_hash1(fi * 2.7));
            float px = seed.x * 2.0 - 1.0;
            float speed = 0.04 + seed.y * 0.08;
            float py = fract(seed.y + t * speed) * 2.0 - 1.0;
            float2 ppos = float2(px, py);
            float d = length(uv - ppos);
            particles += (0.04 + seed.x * 0.08) * smoothstep(0.015, 0.0, d);
        }
        col += EMERALD * particles;
        return float4(col, 1.0);
    }

    float4 phaseInitiating(float2 uv, float t, float progress) {
        float3 col = VOID_BLACK;
        float dist = length(uv);

        float loopT  = fract(t * 0.4 + progress * 0.3);
        float radius = loopT * 1.6;

        float wave   = em_ring(dist, radius, 0.015, 0.012);
        float trail  = em_glow(dist, radius, 8.0) * (1.0 - loopT) * 0.5;
        float center = em_disc(dist, 0.04, 0.02) * (1.0 - loopT * 0.8);

        float intensity = wave + trail + center;
        col += EMERALD * intensity;
        col = mix(VOID_BLACK, col, em_ss(0.0, 0.15, progress));

        return float4(col, 1.0);
    }

    float4 phaseAwaiting(float2 uv, float t, float progress) {
        float3 col = VOID_BLACK;
        float dist = length(uv);

        float breath = 1.0 + 0.12 * sin(t * EM_TAU / 3.0);
        float bdist  = dist / breath;

        float ringMask = em_ring(bdist, 0.45, 0.012, 0.010);
        col += EMERALD * ringMask;

        float halo = em_ring(bdist, 0.45, 0.06, 0.04) * 0.3;
        col += EMERALD * halo;

        float angle  = atan2(uv.y, uv.x);
        float rot    = -t * EM_TAU / 8.0;
        float relAng = fmod(angle - rot + EM_TAU * 2.0, EM_TAU);
        float arcW   = EM_PI / 3.0;
        float arc    = em_ss(arcW, 0.0, relAng) * em_ss(EM_TAU - arcW, EM_TAU, relAng + arcW);
        col += mix(float3(0.0), GHOST_WHITE, arc * ringMask * 0.6);

        return float4(col, 1.0);
    }

    float4 phaseVerifying(float2 uv, float t, float progress) {
        float3 col  = VOID_BLACK;
        float  dist = length(uv);

        float segCount    = 8.0;
        float confirmed   = floor(progress * segCount);
        float partialFill = fract(progress * segCount);

        float ringRadius = 0.45;
        float ringThick  = 0.015;
        float segGap     = EM_TAU / 72.0;
        float segSpan    = EM_TAU / segCount - segGap;

        for (int i = 0; i < 8; i++) {
            float fi = float(i);
            float startAngle = -EM_PI * 0.5 + fi * (EM_TAU / segCount);
            float endAngle   = startAngle + segSpan;

            float ang    = fmod(atan2(uv.y, uv.x) - startAngle + EM_TAU * 2.0, EM_TAU);
            float segArc = fmod(endAngle - startAngle + EM_TAU * 2.0, EM_TAU);
            float inArc  = em_ss(0.002, 0.005, ang) * em_ss(segArc, segArc - 0.005, ang);

            float rMask   = em_ring(dist, ringRadius, ringThick, 0.008) * inArc;
            float segDone = step(fi + 1.0, confirmed + 0.001);
            float segCurr = step(fi, confirmed + 0.001) * (1.0 - segDone);

            float3 segColor = mix(
                GHOST_WHITE * 0.3,
                mix(
                    mix(GHOST_WHITE * 0.3, EMERALD, partialFill),
                    EMERALD,
                    segDone
                ),
                segCurr + segDone
            );
            col += segColor * rMask;

            float flashT    = fract(t * 3.3 + fi * 0.37);
            float flashR    = ringRadius + flashT * 0.25;
            float flashAmp  = (1.0 - flashT) * segDone * 0.5;
            float flashMask = em_ring(dist, flashR, 0.008, 0.01) * inArc;
            col += EMERALD * flashMask * flashAmp;
        }

        col += EMERALD * em_disc(dist, 0.03, 0.02) * 0.4;
        return float4(col, 1.0);
    }

    float4 phaseConfirmed(float2 uv, float t, float progress) {
        float3 col  = VOID_BLACK;
        float  dist = length(uv);

        float shards = 0.0;
        for (int i = 0; i < 32; i++) {
            float fi    = float(i);
            float ang   = em_hash1(fi * 3.7) * EM_TAU;
            float speed = 0.4 + em_hash1(fi * 1.9) * 0.8;
            float r     = progress * speed;
            float dr    = abs(dist - r);
            float da    = abs(fmod(atan2(uv.y, uv.x) - ang + EM_TAU * 2.0, EM_TAU) - EM_PI);
            float shard = em_ss(0.015, 0.0, dr) * em_ss(0.04, 0.01, da);
            float fade  = 1.0 - progress;
            shards += shard * fade;
        }
        col += EMERALD * shards;

        float burstR    = progress * 1.2;
        float burstFade = 1.0 - progress;
        float burstRing = em_ring(dist, burstR, 0.025, 0.015);
        col += EMERALD * burstRing * burstFade;

        float steadyGlow = em_glow(dist, 0.0, 3.5) * progress * 0.6;
        col += EMERALD * steadyGlow;

        col += EMERALD * em_disc(dist, 0.06, 0.03) * em_ss(0.7, 1.0, progress);
        return float4(col, 1.0);
    }

    float4 phaseDeadLink(float2 uv, float t, float progress) {
        float3 col  = VOID_BLACK;
        float  dist = length(uv);

        float rGlow = em_glow(dist, 0.0, 4.0) * (1.0 - progress);
        col += WARN_RED * rGlow;

        float dissolveR = 0.45 * (1.0 - progress);
        float dissolve  = em_ring(dist, dissolveR, 0.012, 0.010) * (1.0 - progress);
        col += mix(EMERALD, WARN_RED, progress) * dissolve;

        col = mix(col, VOID_BLACK, em_ss(0.6, 1.0, progress));
        return float4(col, 1.0);
    }

    float4 phaseGhost(float2 uv, float t, float progress) {
        float3 col  = VOID_BLACK;
        float  dist = length(uv);

        if (progress < 0.5) {
            float rp    = progress * 2.0;
            float r     = 0.45 * (1.0 - rp);
            float rMask = em_ring(dist, r, 0.012 * (1.0 - rp * 0.5), 0.010);
            float3 rCol = mix(EMERALD, ASH_GREY, rp);
            col += rCol * rMask * (1.0 - rp * 0.5);
        }

        float staticAmt = em_ss(0.5, 0.85, progress);
        if (staticAmt > 0.0) {
            float noiseVal = em_noise(uv * 60.0 + t * 5.0);
            col = mix(col, ASH_GREY * noiseVal * 0.8, staticAmt);
        }

        float voidFade = em_ss(0.85, 1.0, progress);
        col = mix(col, VOID_BLACK, voidFade);
        return float4(col, 1.0);
    }

    // --- Fragment entry ---

    fragment float4 emeraldFragment(VertexOut in [[stage_in]],
                                     constant EmeraldUniforms &u [[buffer(0)]]) {
        float2 fragCoord = float2(in.uv.x * u.resolution.x, in.uv.y * u.resolution.y);
        float2 uv = (fragCoord * 2.0 - u.resolution) / min(u.resolution.x, u.resolution.y);
        float t  = u.time;
        float pr = clamp(u.progress, 0.0, 1.0);

        float4 color;

        if      (u.phase == 0) color = phaseIdle(uv, t);
        else if (u.phase == 1) color = phaseInitiating(uv, t, pr);
        else if (u.phase == 2) color = phaseAwaiting(uv, t, pr);
        else if (u.phase == 3) color = phaseVerifying(uv, t, pr);
        else if (u.phase == 4) color = phaseConfirmed(uv, t, pr);
        else if (u.phase == 5) color = phaseDeadLink(uv, t, pr);
        else if (u.phase == 6) color = phaseGhost(uv, t, pr);
        else                   color = float4(VOID_BLACK, 1.0);

        return color;
    }
    """
}
