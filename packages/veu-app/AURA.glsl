// =============================================================================
// AURA.glsl — Veu Protocol: Identity Aura Fragment Shader
// =============================================================================
// Renders the "Aura" — an animated, reactive visual field surrounding a user's
// identity or artifact in the Veu app UI. The Aura is seeded by the user's key
// hash (u_seed_color), making every user's glow visually unique and
// deterministic. This is part of the Glaze generative art engine.
//
// Uniforms:
//   u_time        — elapsed time in seconds, drives animation
//   u_resolution  — viewport dimensions in pixels (width, height)
//   u_seed_color  — RGB color derived from the user's Glaze Seed (HMAC-SHA-256
//                   of their public key hash); encodes the user's unique palette
//   u_pulse       — 0.0–1.0 handshake/sync activity intensity; at 0.0 the aura
//                   is in its resting state, at 1.0 it flares outward
// =============================================================================

precision highp float;

uniform float u_time;
uniform vec2  u_resolution;
uniform vec3  u_seed_color;
uniform float u_pulse;

// -----------------------------------------------------------------------------
// [Stage 0] Utility: 2-D hash — converts a 2-D coordinate to a pseudo-random
// scalar in [0, 1). Used as the basis for all noise functions below.
// -----------------------------------------------------------------------------
float hash(vec2 p) {
    p = fract(p * vec2(127.1, 311.7));
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

// -----------------------------------------------------------------------------
// [Stage 1] Value Noise — smooth interpolation of hashed grid corners.
// Drives the primary distortion field for the aura's organic, undulating shape.
// -----------------------------------------------------------------------------
float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);

    // Quintic smoothstep for C2-continuous interpolation (no derivative
    // discontinuities that would create visible banding).
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// -----------------------------------------------------------------------------
// [Stage 2] Fractal Brownian Motion (fBm) — stacks multiple octaves of value
// noise at increasing frequency and decreasing amplitude. This produces the
// "cloud-like" layered distortion that gives the aura its soft, organic look.
// -----------------------------------------------------------------------------
float fbm(vec2 p) {
    float v     = 0.0;
    float amp   = 0.5;   // starting amplitude
    float freq  = 1.0;   // starting frequency
    float total = 0.0;   // for normalization

    for (int i = 0; i < 5; i++) {
        v     += amp * valueNoise(p * freq);
        total += amp;
        freq  *= 2.1;    // lacunarity — slightly above 2 avoids axis-aligned artefacts
        amp   *= 0.48;   // gain — sub-0.5 keeps the overall range bounded
    }
    return v / total;
}

// -----------------------------------------------------------------------------
// [Stage 3] Iridescence helper — produces a thin-film interference shimmer by
// rotating the hue of the seed color slightly based on view angle (approximated
// via the normal-to-center direction at each fragment).
//
// The shimmer is most visible at the aura's outer edge where the gradient falls
// off; at the center it is dominated by the core glow.
// -----------------------------------------------------------------------------
vec3 iridescence(vec3 baseColor, float edgeFactor, float t) {
    // Hue rotation angle oscillates gently over time and is stronger at edges.
    float angle = edgeFactor * 0.6 + sin(t * 0.7) * 0.15;
    float c = cos(angle);
    float s = sin(angle);

    // Rodrigues-style hue rotation in RGB space (approximate but GPU-cheap).
    // Rotates around the achromatic axis (1,1,1)/sqrt(3).
    mat3 rot = mat3(
        0.299 + 0.701 * c + 0.168 * s,
        0.587 - 0.587 * c + 0.330 * s,
        0.114 - 0.114 * c - 0.497 * s,

        0.299 - 0.299 * c - 0.328 * s,
        0.587 + 0.413 * c + 0.035 * s,
        0.114 - 0.114 * c + 0.292 * s,

        0.299 - 0.300 * c + 1.250 * s,
        0.587 - 0.588 * c - 1.050 * s,
        0.114 + 0.886 * c - 0.203 * s
    );
    return clamp(rot * baseColor, 0.0, 1.0);
}

// =============================================================================
// main — fragment entry point
// =============================================================================
void main() {
    // -------------------------------------------------------------------------
    // [Stage 4] Coordinate setup — normalise to [-1, 1] with correct aspect ratio
    // -------------------------------------------------------------------------
    vec2 uv = (gl_FragCoord.xy * 2.0 - u_resolution) / min(u_resolution.x, u_resolution.y);

    // Radial distance from the center of the aura.
    float dist = length(uv);

    // -------------------------------------------------------------------------
    // [Stage 5] Animated distortion field — two layers of fBm scrolling in
    // slightly different directions create a non-repeating, living distortion.
    // The speed is intentionally slow (×0.15) so the aura feels serene, not
    // frantic.
    // -------------------------------------------------------------------------
    float t = u_time * 0.15;

    vec2 q = vec2(
        fbm(uv + vec2(0.0, t)),
        fbm(uv + vec2(1.7, t * 0.9))
    );

    vec2 r = vec2(
        fbm(uv + 1.5 * q + vec2(1.7, 9.2) + t * 0.12),
        fbm(uv + 1.5 * q + vec2(8.3, 2.8) + t * 0.11)
    );

    float noiseField = fbm(uv + r);

    // -------------------------------------------------------------------------
    // [Stage 6] Pulse modulation — u_pulse (0–1) expands the visible aura
    // radius and increases brightness, giving real-time feedback during
    // handshake and sync activity.
    // -------------------------------------------------------------------------
    float pulseExpand = 1.0 + u_pulse * 0.35;
    float pulseBright = 1.0 + u_pulse * 0.5;

    // Effective "virtual distance" after distortion and pulse expansion.
    float d = (dist - noiseField * 0.25) / pulseExpand;

    // -------------------------------------------------------------------------
    // [Stage 7] Radial glow — a smooth exponential falloff from the center
    // creates the soft radial halo characteristic of the aura.
    // -------------------------------------------------------------------------
    float glow = exp(-d * d * 2.8);

    // A secondary, wider and fainter outer corona.
    float corona = exp(-d * d * 0.6) * 0.35;

    float totalGlow = glow + corona;

    // -------------------------------------------------------------------------
    // [Stage 8] Color — blend the user's seed color toward white at the bright
    // core and toward a darker, desaturated tone at the outer edge.
    // -------------------------------------------------------------------------
    vec3 coreColor  = mix(u_seed_color, vec3(1.0), 0.6);   // bright core
    vec3 edgeColor  = u_seed_color * 0.4;                  // dim edge tint

    // Edge factor: 0 at center, 1 at d = 1 (outer boundary of the visible aura)
    float edgeFactor = clamp(d, 0.0, 1.0);

    vec3 color = mix(coreColor, edgeColor, edgeFactor);

    // -------------------------------------------------------------------------
    // [Stage 9] Iridescence — thin-film shimmer added at the outer edge only,
    // so the core retains the user's clean seed color identity.
    // -------------------------------------------------------------------------
    vec3 iriColor = iridescence(color, edgeFactor, u_time);
    color = mix(color, iriColor, edgeFactor * 0.6);

    // Apply brightness and glow envelope.
    color *= totalGlow * pulseBright;

    // -------------------------------------------------------------------------
    // [Stage 10] Subtle breathing animation — a slow sinusoidal modulation of
    // overall brightness so the aura "breathes" even when u_pulse is 0.
    // -------------------------------------------------------------------------
    float breathe = 0.85 + 0.15 * sin(u_time * 0.5);
    color *= breathe;

    // -------------------------------------------------------------------------
    // [Stage 11] Alpha — the aura is fully transparent where there is no glow,
    // allowing the underlying UI to show through cleanly.
    // -------------------------------------------------------------------------
    float alpha = clamp(totalGlow * pulseBright * breathe, 0.0, 1.0);

    gl_FragColor = vec4(color, alpha);
}
