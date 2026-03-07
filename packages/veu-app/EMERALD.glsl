// =============================================================================
// EMERALD.glsl — Veu Protocol: Emerald Handshake Visual Ceremony
// =============================================================================
// Fragment shader implementing the Emerald Handshake ceremony's seven visual
// states.  Each phase maps to a distinct shader sub-routine; the app layer
// drives the transitions by writing to the uniforms below.
//
// Uniforms:
//   u_phase      — current ceremony phase (see constants below)
//   u_time       — elapsed time in seconds (continuous, not reset per phase)
//   u_resolution — viewport dimensions in pixels
//   u_progress   — 0.0–1.0 position within the current phase
//
// Phase constants:
//   0 = IDLE        quiet void, faint green particle drift
//   1 = INITIATING  single green pulse ray expanding outward
//   2 = AWAITING    slow rotating emerald ring, breathing
//   3 = VERIFYING   8-segment pulse-lock ring filling in per confirmed digit
//   4 = CONFIRMED   emerald bloom burst + crystalline shatter pattern
//   5 = DEAD_LINK   red-to-black fade, ring dissolves
//   6 = GHOST       bloom rewinds, drains to grey static, fades to void
// =============================================================================

precision highp float;

uniform int   u_phase;
uniform float u_time;
uniform vec2  u_resolution;
uniform float u_progress;

// -----------------------------------------------------------------------------
// Palette
// -----------------------------------------------------------------------------
const vec3 EMERALD     = vec3(0.314, 0.784, 0.471);  // #50C878
const vec3 GHOST_WHITE = vec3(0.973, 0.973, 1.000);  // #F8F8FF
const vec3 VOID_BLACK  = vec3(0.039, 0.039, 0.039);  // #0A0A0A
const vec3 WARN_RED    = vec3(0.784, 0.251, 0.251);  // #C84040
const vec3 ASH_GREY    = vec3(0.533, 0.533, 0.533);  // #888888

// PI constant
const float PI  = 3.14159265359;
const float TAU = 6.28318530718;

// =============================================================================
// Utility functions shared by multiple phases
// =============================================================================

// 2-D pseudo-random hash — deterministic, GPU-cheap.
float hash(vec2 p) {
    p = fract(p * vec2(127.1, 311.7));
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

// 1-D hash.
float hash1(float n) { return fract(sin(n) * 43758.5453); }

// Smooth 2-D value noise.
float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i),                hash(i + vec2(1.0, 0.0)), u.x),
        mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
        u.y);
}

// Smooth-step helper.
float ss(float a, float b, float t) { return smoothstep(a, b, t); }

// Anti-aliased ring.  Returns 1.0 on the ring, 0.0 off.
float ring(float dist, float radius, float thickness, float aa) {
    float d = abs(dist - radius) - thickness * 0.5;
    return 1.0 - ss(0.0, aa, d);
}

// Anti-aliased filled disc.
float disc(float dist, float radius, float aa) {
    return 1.0 - ss(radius - aa, radius + aa, dist);
}

// Soft radial glow.
float glow(float dist, float radius, float falloff) {
    float d = max(0.0, dist - radius);
    return exp(-d * falloff);
}

// =============================================================================
// Phase sub-routines
// =============================================================================

// -----------------------------------------------------------------------------
// [Phase 0] IDLE — quiet void with faint green particle drift
// -----------------------------------------------------------------------------
vec4 phaseIdle(vec2 uv, float t) {
    // Background: void-black.
    vec3 col = VOID_BLACK;

    // Particle field: sparse bright specks drifting upward.
    // Each "particle" is a tiny disc at a pseudo-random position that scrolls
    // vertically and wraps at the top.
    float particles = 0.0;
    for (int i = 0; i < 24; i++) {
        float fi = float(i);
        // Random position seed per particle.
        vec2 seed = vec2(hash1(fi * 1.3), hash1(fi * 2.7));
        // Horizontal position: fixed per particle.
        float px = seed.x * 2.0 - 1.0;
        // Vertical position: scrolls upward at a unique speed, wraps.
        float speed = 0.04 + seed.y * 0.08;
        float py = fract(seed.y + t * speed) * 2.0 - 1.0;
        vec2  ppos = vec2(px, py);
        float d = length(uv - ppos);
        // Particle brightness: faint (max ~0.12).
        particles += (0.04 + seed.x * 0.08) * smoothstep(0.015, 0.0, d);
    }

    col += EMERALD * particles;
    return vec4(col, 1.0);
}

// -----------------------------------------------------------------------------
// [Phase 1] INITIATING — single emerald pulse ray expanding outward
// -----------------------------------------------------------------------------
vec4 phaseInitiating(vec2 uv, float t, float progress) {
    vec3 col = VOID_BLACK;
    float dist = length(uv);

    // The shockwave radius grows continuously, driven by u_progress (loop).
    float loopT  = fract(t * 0.4 + progress * 0.3);
    float radius = loopT * 1.6;

    // Bright leading edge.
    float wave = ring(dist, radius, 0.015, 0.012);
    // Soft trailing glow behind the wavefront.
    float trail = glow(dist, radius, 8.0) * (1.0 - loopT) * 0.5;
    // Center origin pulse.
    float center = disc(dist, 0.04, 0.02) * (1.0 - loopT * 0.8);

    float intensity = wave + trail + center;
    col += EMERALD * intensity;

    // Fade in at the very start of the phase to avoid a hard cut.
    col = mix(VOID_BLACK, col, ss(0.0, 0.15, progress));

    return vec4(col, 1.0);
}

// -----------------------------------------------------------------------------
// [Phase 2] AWAITING — slow rotating emerald ring with breathing
// -----------------------------------------------------------------------------
vec4 phaseAwaiting(vec2 uv, float t, float progress) {
    vec3 col = VOID_BLACK;
    float dist = length(uv);

    // Breathing: scale the effective distance so the ring appears to pulse in
    // and out with a ~3-second period.
    float breath  = 1.0 + 0.12 * sin(t * TAU / 3.0);
    float bdist   = dist / breath;

    // Main ring.
    float ringMask = ring(bdist, 0.45, 0.012, 0.010);
    col += EMERALD * ringMask;

    // Soft outer glow halo around the ring.
    float halo = ring(bdist, 0.45, 0.06, 0.04) * 0.3;
    col += EMERALD * halo;

    // Rotating highlight: a bright arc that sweeps around the ring.
    float angle  = atan(uv.y, uv.x);
    float rot    = -t * TAU / 8.0;           // 1 revolution per 8 s, CCW
    float relAng = mod(angle - rot, TAU);    // normalised to [0, TAU)
    // Highlight arc spans ~60° (PI/3 radians).
    float arcW   = PI / 3.0;
    float arc    = ss(arcW, 0.0, relAng) * ss(TAU - arcW, TAU, relAng + arcW);
    // Blend into ring only where the ring mask is non-zero.
    col += mix(vec3(0.0), GHOST_WHITE, arc * ringMask * 0.6);

    return vec4(col, 1.0);
}

// -----------------------------------------------------------------------------
// [Phase 3] VERIFYING — 8-segment pulse-lock ring
// -----------------------------------------------------------------------------
vec4 phaseVerifying(vec2 uv, float t, float progress) {
    vec3  col  = VOID_BLACK;
    float dist = length(uv);

    // Decode progress into confirmed segments and in-progress fill fraction.
    // 8 segments → each represents 0.125 of the full progress range.
    float segCount = 8.0;
    float confirmed    = floor(progress * segCount);       // 0..8 whole segments
    float partialFill  = fract(progress * segCount);       // 0..1 fill of next seg

    float ringRadius = 0.45;
    float ringThick  = 0.015;
    float segGap     = TAU / 72.0;   // ~5° gap between segments
    float segSpan    = TAU / segCount - segGap;

    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        // Counter-clockwise from 12 o'clock: offset by -PI/2.
        float startAngle = -PI * 0.5 + fi * (TAU / segCount);
        float endAngle   = startAngle + segSpan;

        // Determine if the current fragment is within this segment's arc.
        float ang = mod(atan(uv.y, uv.x) - startAngle + TAU, TAU);
        float segArc = mod(endAngle - startAngle + TAU, TAU);
        float inArc  = ss(0.002, 0.005, ang) * ss(segArc, segArc - 0.005, ang);

        // Compute the ring mask for this fragment.
        float rMask = ring(dist, ringRadius, ringThick, 0.008) * inArc;

        // Determine color / brightness.
        float segDone = step(fi + 1.0, confirmed + 0.001);             // fully confirmed?
        float segCurr = step(fi, confirmed + 0.001) * (1.0 - segDone); // currently filling?

        vec3 segColor = mix(
            GHOST_WHITE * 0.3,                          // dim: not yet reached
            mix(
                mix(GHOST_WHITE * 0.3, EMERALD, partialFill),  // in-progress gradient
                EMERALD,                                         // fully confirmed
                segDone
            ),
            segCurr + segDone
        );

        col += segColor * rMask;

        // Flash pulse: emit a brief outward ring when a segment becomes fully lit.
        // The flash is approximated by a fast per-segment oscillation (staggered by
        // segment index) masked by segDone so it only fires on confirmed segments.
        // App-layer note: for a precisely timed single-fire flash the app should
        // snapshot u_time at the moment each segment confirms and pass it as an
        // additional uniform (e.g. u_segment_confirm_times[8]).  The current
        // implementation uses a periodic approximation that is visually close enough
        // for the default implementation.
        float flashT   = fract(t * 3.3 + fi * 0.37);   // stagger per segment
        float flashR   = ringRadius + flashT * 0.25;
        float flashAmp = (1.0 - flashT) * segDone * 0.5;
        float flashMask = ring(dist, flashR, 0.008, 0.01) * inArc;
        col += EMERALD * flashMask * flashAmp;
    }

    // Soft center dot as focus anchor.
    col += EMERALD * disc(dist, 0.03, 0.02) * 0.4;

    return vec4(col, 1.0);
}

// -----------------------------------------------------------------------------
// [Phase 4] CONFIRMED — emerald bloom burst + crystalline shatter
// -----------------------------------------------------------------------------
vec4 phaseConfirmed(vec2 uv, float t, float progress) {
    vec3  col  = VOID_BLACK;
    float dist = length(uv);

    // Shatter phase: shards travel outward.  Each shard is a thin radial line
    // segment emitted from a pseudo-random angle.
    float shards = 0.0;
    for (int i = 0; i < 32; i++) {
        float fi    = float(i);
        float ang   = hash1(fi * 3.7) * TAU;   // random angle
        float speed = 0.4 + hash1(fi * 1.9) * 0.8;
        float r     = progress * speed;        // how far the shard has traveled
        float dr    = abs(dist - r);
        float da    = abs(mod(atan(uv.y, uv.x) - ang + TAU, TAU) - PI);
        // Shard: thin angular slice at the traveling radius.
        float shard = ss(0.015, 0.0, dr) * ss(0.04, 0.01, da);
        float fade  = 1.0 - progress;          // shards fade as they travel
        shards += shard * fade;
    }
    col += EMERALD * shards;

    // Bloom: an expanding bright ring that's the "burst" moment.
    float burstR    = progress * 1.2;
    float burstFade = 1.0 - progress;
    float burstRing = ring(dist, burstR, 0.025, 0.015);
    col += EMERALD * burstRing * burstFade;

    // Steady glow that builds as progress approaches 1 (the settled state).
    float steadyGlow = glow(dist, 0.0, 3.5) * progress * 0.6;
    col += EMERALD * steadyGlow;

    // Center core — full brightness at progress = 1.
    col += EMERALD * disc(dist, 0.06, 0.03) * ss(0.7, 1.0, progress);

    return vec4(col, 1.0);
}

// -----------------------------------------------------------------------------
// [Phase 5] DEAD_LINK — red glow bleeds out then fades to void-black
// -----------------------------------------------------------------------------
vec4 phaseDeadLink(vec2 uv, float t, float progress) {
    vec3  col  = VOID_BLACK;
    float dist = length(uv);

    // Red center glow bleeds out and fades as progress increases.
    float rGlow = glow(dist, 0.0, 4.0) * (1.0 - progress);
    col += WARN_RED * rGlow;

    // Dissolving ring: the previous ring (from AWAITING) shrinks and fades.
    float dissolveR = 0.45 * (1.0 - progress);
    float dissolve  = ring(dist, dissolveR, 0.012, 0.010) * (1.0 - progress);
    col += mix(EMERALD, WARN_RED, progress) * dissolve;

    // The whole scene cross-fades to void-black over progress.
    col = mix(col, VOID_BLACK, ss(0.6, 1.0, progress));

    return vec4(col, 1.0);
}

// -----------------------------------------------------------------------------
// [Phase 6] GHOST — bloom rewinds, drains to grey static, cuts to void
// -----------------------------------------------------------------------------
vec4 phaseGhost(vec2 uv, float t, float progress) {
    vec3  col  = VOID_BLACK;
    float dist = length(uv);

    // Phase 1 (0.0–0.5): rewind the confirmed bloom — ring collapses inward
    // and color drains from emerald to ash-grey.
    if (progress < 0.5) {
        float rp    = progress * 2.0;    // 0..1 within rewind stage
        float r     = 0.45 * (1.0 - rp);
        float rMask = ring(dist, r, 0.012 * (1.0 - rp * 0.5), 0.010);
        vec3  rCol  = mix(EMERALD, ASH_GREY, rp);
        col += rCol * rMask * (1.0 - rp * 0.5);
    }

    // Phase 2 (0.5–0.85): dissolve into static grey noise.
    float staticAmt = ss(0.5, 0.85, progress);
    if (staticAmt > 0.0) {
        float noiseVal = noise(uv * 60.0 + t * 5.0);
        col = mix(col, ASH_GREY * noiseVal * 0.8, staticAmt);
    }

    // Phase 3 (0.85–1.0): fade to void-black.
    float voidFade = ss(0.85, 1.0, progress);
    col = mix(col, VOID_BLACK, voidFade);

    return vec4(col, 1.0);
}

// =============================================================================
// main — route to the correct phase sub-routine
// =============================================================================
void main() {
    // Normalise coordinates to [-1, 1] with correct aspect ratio.
    vec2 uv = (gl_FragCoord.xy * 2.0 - u_resolution) / min(u_resolution.x, u_resolution.y);
    float t  = u_time;
    float pr = clamp(u_progress, 0.0, 1.0);

    vec4 color;

    if      (u_phase == 0) color = phaseIdle(uv, t);
    else if (u_phase == 1) color = phaseInitiating(uv, t, pr);
    else if (u_phase == 2) color = phaseAwaiting(uv, t, pr);
    else if (u_phase == 3) color = phaseVerifying(uv, t, pr);
    else if (u_phase == 4) color = phaseConfirmed(uv, t, pr);
    else if (u_phase == 5) color = phaseDeadLink(uv, t, pr);
    else if (u_phase == 6) color = phaseGhost(uv, t, pr);
    else                   color = vec4(VOID_BLACK, 1.0);  // unknown phase → safe default

    gl_FragColor = color;
}
