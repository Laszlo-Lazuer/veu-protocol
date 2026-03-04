# veu-auth: Hardware Attestation & Compromise Detection

Because Veu is decentralized, we rely on the **Secure Enclave** and **Apple App Attest** to prove that every peer in a Circle is running on genuine, non-tampered hardware.

## 🛡️ The Attestation Protocol

### 1. Hardware-Signed Identity
Every **Ghost Identity** is bound to a physical A14+ chip via **App Attest**.
- **The Challenge:** When Alice joins a Circle, her device generates an Attestation Key.
- **The Proof:** Her device sends a hardware-signed statement to the other peers.
- **Verification:** Peers verify the signature against Apple's public root certificate. If the signature is invalid (indicating a jailbroken or simulated device), Alice is blocked.

### 2. Sandbox Violation & Panic Logic
The app continuously monitors its own process for hooks or debuggers.
- **Detection:** If a debugger is attached or the sandbox is breached (Jailbreak).
- **Reaction (Instant Burn):** 
  - All **Circle Keys** are purged from volatile memory.
  - The **Circle Ledger** is re-encrypted with a "Panic Key."
  - The app enters a "Halt" state until a 24-word recovery is performed on a clean device.

### 3. The "Cloned Identity" Alarm
If two devices broadcast the same **Identity Master Key** but provide different **App Attest** tokens, the protocol detects a "Seed Leak."
- **Action:** The Circle is automatically "Frozen." No new artifacts can be synced until the real owner initiates an **Identity Burn** to rotate all keys.

## 🛠️ Apple DeviceCheck Integration
Veu leverages the 2-bit state provided by Apple's **DeviceCheck** to maintain an anonymous "Device Reputation."
- **Bit 0 (Malice Flag):** Set if the device is caught attempting a brute-force or replay attack.
- **Bit 1 (Compromised Flag):** Set if the hardware fails an automated integrity audit.

---
*Note: This layer ensures that Veu isn't just "software-secure," but is mathematically tethered to the physical iPhone hardware.*