# EMERALD_HANDSHAKE.md — Veu Protocol: Emerald Handshake Visual States

> **Scope:** This document bridges the `veu-crypto` key-exchange layer and the
> `veu-app` rendering layer.  It defines the five successful phases of the
> Curve25519 Emerald Handshake ceremony plus two failure states ("Dead Link" and
> "Ghost"), for a total of **seven visual phases** (phases 0–6).  For each phase
> it documents the cryptographic event that triggers it, the corresponding
> visual/shader state that EMERALD.glsl must render, and the expected uniform
> values.

---

## 1. Overview

The **Emerald Handshake** is the Veu protocol's Circle connection ceremony.
Two users establish a shared Circle key using an X25519 Diffie-Hellman key
exchange augmented by a short-code out-of-band verification step.  The
ceremony is fully end-to-end: no server ever sees either party's private key
material or the derived shared secret.

The visual ceremony rendered by `EMERALD.glsl` gives both parties continuous,
aesthetically coherent feedback about the cryptographic state of the
handshake.  The colors are drawn from the Emerald palette:

| Token | Hex | Role |
|-------|-----|------|
| Emerald | `#50C878` | primary active state, trust, completion |
| Ghost-white | `#F8F8FF` | neutral / awaiting / verifying accent |
| Void-black | `#0A0A0A` | background, failure, death |
| Warn-red | `#C84040` | Dead Link failure |
| Ash-grey | `#888888` | Ghost failure |

---

## 2. Handshake Phases

### Phase 0 — `IDLE`

**Cryptographic event:** No handshake in progress.  The local device has not
yet generated an ephemeral X25519 keypair for a new Circle invitation.

**Visual state (`u_phase = 0`):**
- A quiet void-black field.
- Sparse, faint green (`#50C878` at ≈10 % opacity) particles drift slowly
  upward, representing latent cryptographic entropy.
- No rings, no pulses — the system is at rest.
- Shader parameter: `u_progress` is ignored in this phase.

---

### Phase 1 — `INITIATING`

**Cryptographic event:** The *initiating* peer has:
1. Generated a fresh ephemeral X25519 keypair `(esk_A, epk_A)`.
2. Encoded `epk_A` plus a protocol version tag into a Dead Link URL / QR code.
3. Started the invitation expiry timer (default: 10 minutes).

**Visual state (`u_phase = 1`):**
- A single bright emerald ray pulses outward from the center.
- The ray expands as a radial shockwave that fades at the viewport edge.
- `u_progress` (0.0–1.0) controls the radius of the shockwave front.
- Animation loops continuously until the peer responds or the link expires.
- Conveys: "I have sent the invitation; waiting for the other side."

---

### Phase 2 — `AWAITING`

**Cryptographic event:** The *responding* peer has:
1. Scanned / received the Dead Link.
2. Parsed `epk_A` and generated their own ephemeral keypair `(esk_B, epk_B)`.
3. Sent `epk_B` back to the initiating peer over the Ghost Network relay.

Both peers are now waiting to compute the shared secret and begin short-code
verification.

**Visual state (`u_phase = 2`):**
- A slow-rotating emerald ring, centered, with a soft breathing pulse.
- Ring rotation speed: approximately 1 revolution per 8 seconds.
- Breathing period: approximately 3 seconds (scale oscillates ±12 %).
- `u_progress` maps to the ring's current rotation angle (0 = just started,
  1.0 = one full rotation, wrapping continuously).
- Conveys: "We are connected; computing shared secret."

---

### Phase 3 — `VERIFYING`

**Cryptographic event:** Both peers have independently computed:

```
shared_secret = X25519(esk_local, epk_remote)
circle_key    = HKDF-SHA-256(shared_secret, salt="veu-circle-v1", info=circle_id)
short_code    = first 4 bytes of HMAC-SHA-256(circle_key, "short-code") → 8 hex digits
```

Each peer displays the same 8-digit short code.  The users verify the code
out-of-band (e.g., by reading it aloud or comparing screens).  As each digit
pair is confirmed, the UI calls the shader with an incrementally higher
`u_progress`.

**Visual state (`u_phase = 3`):**
- A "lock ring" composed of 8 arc segments arranged in a tight circle.
- Each segment corresponds to one pair of digits in the 8-digit short code.
- Unconfirmed segments: dim ghost-white (`#F8F8FF` at 30 % opacity).
- Confirmed segments: bright emerald (`#50C878` at full opacity), with a
  brief flash animation on the transition.
- `u_progress` (0.0–1.0) encodes the fraction of confirmed segments:
  - 0.0 = no digits confirmed (all segments dim)
  - 0.125 per confirmed segment (8 segments × 0.125 = 1.0 at full confirmation)
  - Intermediate values show a partial fill on the in-progress segment.
- This is the **"pulse lock" animation**: as each segment lights up the ring
  emits a short outward pulse in emerald.
- Conveys: "Digit-by-digit verification in progress."

---

### Phase 4 — `CONFIRMED`

**Cryptographic event:** Both peers have confirmed all 8 digits.  The
`circle_key` is now stored in the Secure Enclave on each device.  The
ephemeral keys `esk_A` and `esk_B` are immediately zeroed from memory.

**Visual state (`u_phase = 4`):**
- A full **emerald bloom burst**: the completed lock ring explodes outward
  into a crystalline shatter pattern of emerald shards.
- Shards travel along pseudo-random radial vectors derived from the short
  code (seeded by `u_progress` at entry into this phase = 1.0).
- The shatter fades over approximately 1.5 seconds, leaving a steady
  emerald glow as the "confirmed" resting state.
- `u_progress` drives the bloom animation: 0.0 = burst begins, 1.0 = shards
  have fully dispersed and the steady glow has stabilised.
- Conveys: "Circle connection established — trust is crystallised."

---

## 3. Failure States

### Dead Link (`u_phase = 5`)

**Cryptographic event:** The Dead Link invitation URL has expired (10-minute
TTL elapsed) or was explicitly revoked by the initiating peer.  The ephemeral
keypair `(esk_A, epk_A)` is zeroed; the invitation is cryptographically dead.

**Visual state (`u_phase = 5`):**
- A red (`#C84040`) glow appears at the center and bleeds outward.
- Over the duration of `u_progress` (0.0–1.0) the red fades to void-black,
  and the previously visible ring or ray dissolves from the outside in.
- Conveys: "This invitation link has expired and can never be reused."

---

### Ghost (`u_phase = 6`)

**Cryptographic event:** The handshake was not completed within the protocol
timeout (e.g., the responding peer rejected the short code, network
connectivity was lost, or no response was received within the session window).
All ephemeral key material is zeroed.

**Visual state (`u_phase = 6`):**
- The most recently active phase's visual (e.g., the AWAITING ring or the
  VERIFYING lock) *rewinds* in reverse, decelerating as it collapses.
- The color drains from emerald toward ash-grey (`#888888`).
- As `u_progress` approaches 1.0 the image dissolves into grey static noise,
  as if the signal was lost — then cuts to void-black.
- Conveys: "The handshake timed out or was rejected.  No key was established."

---

## 4. Short-Code Pulse-Lock Animation Detail

The "pulse lock" in `VERIFYING` is the most mechanically precise visual in
the ceremony.  The implementation in `EMERALD.glsl` should follow these rules:

1. **Segment geometry:** 8 arcs, each spanning 40° of a 360° ring, with 5°
   gaps between arcs.  Ring radius: ~45 % of the shorter viewport dimension.
2. **Segment fill order:** counter-clockwise from the 12 o'clock position,
   matching the left-to-right reading order of the 8-digit code display.
3. **Flash animation:** when a segment transitions from dim to lit, the shader
   emits a radial pulse (a brief bright ring) that expands from the segment
   arc and fades over ~0.3 s.
4. **`u_progress` mapping:**
   - `floor(u_progress × 8.0)` = number of fully confirmed segments.
   - `fract(u_progress × 8.0)` = fill amount of the currently-in-progress
     segment (0.0 = empty arc, 1.0 = full arc, transitions to next segment).
5. **Color interpolation:** the in-progress segment interpolates its color
   between ghost-white and emerald using the fractional fill amount above,
   giving a smooth "loading bar" feel within each arc.

---

## 5. Integration Notes

- The app layer is responsible for mapping cryptographic events to phase
  transitions and computing `u_progress`.
- Phase transitions should be animated with a cross-fade of ≤ 200 ms so the
  visual ceremony feels continuous rather than jarring.
- `EMERALD.glsl` should be stateless with respect to phase history; all
  temporal state is encoded in `u_time`, `u_phase`, and `u_progress`.
- On low-power devices (battery saver mode) the shader may reduce particle
  count and disable the iridescence pass without changing the phase semantics.
