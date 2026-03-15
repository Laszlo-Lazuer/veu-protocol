# Traffic Analysis Hardening Plan

> Protecting Veu users from ISP-level surveillance and network-layer metadata analysis.

## Threat Model

Even with end-to-end encryption, an ISP (or any on-path network observer) can extract metadata:

| Threat | What ISP Sees | Risk |
|---|---|---|
| **Destination identification** | DNS queries to `veu-relay.fly.dev`, TLS SNI in ClientHello | Knows user is using Veu |
| **Message type fingerprinting** | Packet sizes (12B text vs 2MB photo) | Infers activity type |
| **Timing correlation** | Alice sends at T, Bob receives at T+δ | Links sender↔receiver |
| **Local network discovery** | mDNS/Bonjour broadcasts on LAN | Identifies nearby Veu users |

**What ISP cannot see today:** message content, recipient identity (topic hashes), photos, keys, circle membership.

---

## Layer 1 — Message Padding (App-Level)

> **Goal:** Eliminate message-size fingerprinting.

### Approach
Pad all outbound WebSocket frames to fixed bucket sizes before transmission. The relay forwards padded frames as-is; the recipient strips padding after decryption.

### Bucket Strategy
| Bucket | Size | Use Case |
|---|---|---|
| Small | 4 KB | Text messages, acks, handshake signals |
| Medium | 64 KB | Short voice clips, small data |
| Large | 256 KB | Compressed photos, longer audio |
| XL | 2 MB | Full-resolution artifacts (relay budget cap) |

### Implementation

**Client (`GlobalTransport` / `InviteService`):**
- Before sending any WebSocket frame, pad the encrypted payload with random bytes to the next bucket boundary
- Prepend a 4-byte little-endian length header (actual payload size) before padding
- Format: `[4B actual_length][payload][random_padding_to_bucket]`

**Relay (`veu-relay`):**
- No changes required — relay already treats payloads as opaque encrypted blobs
- Store-and-forward preserves padding; recipients strip it client-side

**Recipient:**
- Read first 4 bytes as payload length
- Slice `payload[4..<4+length]`, discard remaining padding
- Proceed with decryption as normal

### Cost
- Bandwidth overhead: ~2-5× for small text messages (12B → 4KB), negligible for photos already near bucket sizes
- Relay storage: minimal increase (most artifacts already near 2MB cap)
- CPU: negligible (memcpy + random fill)

---

## Layer 2 — Cover Traffic (App-Level)

> **Goal:** Mask timing patterns to prevent send/receive correlation.

### Approach
Generate periodic encrypted no-op messages between client and relay that are indistinguishable from real traffic. This creates a constant baseline of activity, making it impossible to correlate "Alice sent at T" with "Bob received at T+δ."

### Design
- **Interval:** Random jitter between 15-45 seconds while WebSocket is connected
- **Payload:** Random bytes padded to the Small bucket (4KB) — identical in size/structure to real messages
- **Topic:** Sent to a deterministic cover topic derived from the device's public key: `SHA256("veu-cover-v1:" + deviceID)`
- **Relay handling:** Relay receives, finds no subscribers on cover topic, discards silently (no storage cost)
- **Activation:** Only while app is in foreground with active WebSocket — no background battery drain

### Enhancements (Future)
- **Bidirectional cover:** Relay sends dummy frames back to client at random intervals
- **Adaptive rate:** Increase cover traffic rate during actual message bursts to smooth the pattern
- **Background cover:** Short BGAppRefreshTask bursts (iOS limits to ~30s) to maintain baseline when backgrounded

### Cost
- Bandwidth: ~5-15 KB/min per connected client (1 × 4KB frame every 15-45s)
- Relay CPU: negligible (receive + discard)
- Battery: minimal — one small WebSocket write every ~30s

---

## Layer 3 — DNS-over-HTTPS (App-Level)

> **Goal:** Hide DNS queries from ISP.

### Approach
Use Apple's native `NEDNSSettingsManager` or manual DoH resolution to route all DNS through an encrypted resolver (e.g., Cloudflare `1.1.1.1` or Apple's iCloud Private Relay DNS).

### Implementation Options

**Option A: `NEDNSSettingsManager` (Network Extension)**
- Requires Network Extension entitlement and a DNS Settings profile
- System-wide DoH for the app's process
- Pros: covers all DNS; Cons: requires entitlement approval, adds complexity

**Option B: Manual DoH in `GlobalTransport`**
- Resolve `veu-relay.fly.dev` via HTTPS GET to `https://cloudflare-dns.com/dns-query?name=veu-relay.fly.dev&type=A`
- Cache the resolved IP; connect WebSocket directly to IP with `Host` header
- Pros: no entitlement needed, simple; Cons: only covers relay DNS, not Safari views

**Recommended:** Option B for initial implementation (covers the critical relay connection). Option A as a follow-up if full-app DoH is needed.

### Cost
- Zero monetary cost (Cloudflare DoH is free)
- One additional HTTPS request on app launch / reconnect (~50ms)

### Note
If Layer 4 (Domain Fronting) is implemented, this layer becomes redundant for the relay connection — ISP sees Cloudflare IPs regardless of DNS. Retain for non-relay connections (e.g., any future HTTPS calls).

---

## Layer 4 — Domain Fronting via CDN (Infrastructure)

> **Goal:** Hide that traffic is destined for Veu's relay server.

### Approach
Place the relay behind Cloudflare (or similar CDN). The ISP sees TLS connections to Cloudflare IP addresses with SNI `cdn.cloudflare.com` — indistinguishable from any other Cloudflare-hosted site.

### Architecture
```
Client → TLS (SNI: cloudflare) → Cloudflare Edge → Origin: veu-relay.fly.dev
```

### Implementation
1. **Cloudflare setup:** Add `relay.veuprotocol.com` (or similar) as a proxied DNS record pointing to `veu-relay.fly.dev`
2. **Enable Cloudflare proxy (orange cloud):** All traffic routes through CF edge
3. **WebSocket support:** Cloudflare supports WebSocket proxying on all plans
4. **Client update:** Change relay URL from `wss://veu-relay.fly.dev/ws` to `wss://relay.veuprotocol.com/ws`
5. **Fallback:** Keep direct relay URL as fallback if CDN is unreachable

### Cost
- Cloudflare Free plan: $0 (includes WebSocket proxying, unlimited bandwidth)
- Cloudflare Pro plan: $20/mo (if advanced features needed — WAF, analytics)
- Domain registration: ~$10-15/year if not already owned

---

## Layer 5 — Encrypted Client Hello (Infrastructure)

> **Goal:** Hide SNI in TLS handshake from ISP.

### Approach
TLS Encrypted Client Hello (ECH) encrypts the SNI field using a public key published in DNS. The ISP sees a TLS connection but cannot determine the destination hostname.

### Prerequisites
- Cloudflare supports ECH on proxied domains (Layer 4 must be implemented first)
- Client must use a TLS stack that supports ECH (Apple's Network.framework added ECH support in iOS 17+)

### Implementation
1. **Enable ECH on Cloudflare:** Automatic for proxied domains (no config needed beyond Layer 4)
2. **Client verification:** Ensure `URLSession` / `NWConnection` negotiates ECH when available
3. **Fallback:** If ECH negotiation fails, connection proceeds with plaintext SNI (graceful degradation)

### Cost
- Zero additional cost (included with Cloudflare proxy)
- Requires iOS 17+ for client-side support (already our minimum target)

---

## Implementation Priority

| Priority | Layer | Effort | Impact | Dependencies |
|---|---|---|---|---|
| **P0** | Message Padding | 1-2 days | High — defeats size analysis | None |
| **P0** | Cover Traffic | 1-2 days | High — defeats timing correlation | None |
| **P1** | Domain Fronting (CDN) | 0.5 day | High — hides destination | Domain + Cloudflare account |
| **P1** | ECH | 0 (automatic) | High — hides SNI | Domain Fronting (Layer 4) |
| **P2** | DNS-over-HTTPS | 1 day | Medium — redundant if CDN deployed | None (standalone) |

### Recommended Order
1. **Message Padding + Cover Traffic** — highest impact, zero infrastructure, purely app-side
2. **Domain Fronting + ECH** — one Cloudflare setup covers both; eliminates destination identification
3. **DNS-over-HTTPS** — only if domain fronting is delayed; otherwise skip (redundant)

---

## Success Criteria

After full implementation, an ISP observer should see:
- ✅ TLS connections to generic Cloudflare IPs (indistinguishable from millions of other sites)
- ✅ Encrypted SNI (no hostname visible in handshake)
- ✅ Uniform-sized encrypted frames at regular intervals (no message type fingerprinting)
- ✅ Constant traffic baseline (cannot distinguish idle from active messaging)
- ❌ Cannot determine: app identity, message content, recipients, timing of real messages, message types

## Files Expected to Change

| File | Changes |
|---|---|
| `packages/veu-mesh/Sources/VeuMesh/Transports/GlobalTransport.swift` | Padding encode/decode, cover traffic timer |
| `packages/veu-app/Sources/VeuApp/Services/InviteService.swift` | Padding for invite WebSocket frames |
| `services/veu-relay/internal/ws/hub.go` | Cover topic discard logic (optional) |
| `apps/VeuDemo/Sources/AppCoordinator.swift` | Relay URL update (CDN domain) |
| Infrastructure: Cloudflare DNS + proxy config | Domain fronting + ECH |
