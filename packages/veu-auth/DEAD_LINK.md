# veu-auth: Dead Link Burners (The Ephemeral Invite)

In the Veu protocol, an invitation is not a "Friend Request"—it is a volatile, one-time cryptographic bridge. To maintain the "Island" security model, invite links are designed to "self-destruct" to prevent unauthorized entry via leaked or shared URLs.

## 🔗 The Anatomy of a Dead Link

A Veu invite link is a URI containing:
- **id**: A unique session ID for the handshake.
- **pk**: Alice's Handshake Public Key (ephemeral).
- **sig**: A signature proving Alice generated this link.
- **exp**: A Unix timestamp for expiration.

## 🧨 Burn Mechanisms

### 1. One-Time Use (Single-Entry)
Once a Bob scans or clicks the link and initiates the Emerald Handshake, the link is marked as BURNED in Alice's local state.
- Alice's Device: Immediately stops listening for handshake requests on that specific id.
- Bob's Device: If he tries to re-use the link, it will fail the handshake because the session secret has been purged from Alice's Secure Enclave.

### 2. Time-Based Evaporation (5-Minute Window)
Links are inherently "hot." If not used within a 5-minute window, they expire.
- Secure Enclave Enforcement: The temporary private key associated with the link is stored in volatile memory and is purged automatically after 300 seconds.
- No Residual Data: Even if a malicious actor intercepts the link after 5 minutes, it is mathematically useless as the corresponding private key no longer exists anywhere in the world.

### 3. The "Manual Burn" (Panic Button)
A user can "Recall" all active invite links at any time.
- Action: Alice taps "Burn All Invites" in the app.
- Effect: Every ephemeral session key is wiped from her device, rendering all previously shared links (QR or text) dead instantly.

## 🛡️ Security Guarantees
- No Permanent Link: There is no "Profile URL" that anyone can search or find.
- Non-Transferable: Because the link contains a specific exp and id, it cannot be harvested for a "database of users."
- Ghost Entry: The invite link contains no PII. It reveals nothing about Alice's real name or public callsign until the Emerald Handshake is completed.