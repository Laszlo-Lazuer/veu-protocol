# veu-auth: The Circle Ledger

The Circle Ledger is the local, encrypted database that stores all relationships, keys, and identity mappings. It is the "source of truth" for the device and never leaves the Secure Enclave-protected storage.

## 🗄️ Storage Architecture
- **Location:** App-specific encrypted container (iOS Data Protection).
- **Encryption:** AES-256-GCM using a key wrapped by the **Secure Enclave**.
- **Format:** SQLite (for performance) or Protocol Buffers.

## 📊 Ledger Schema

### 1. The `Circles` Table
Each "Circle" is an isolated cryptographic island.
| Field | Type | Description |
| :--- | :--- | :--- |
| `circle_id` | UUID | Internal local identifier. |
| `circle_key` | 256-bit Key | The symmetric key used to decrypt content in this circle. |
| `glaze_salt` | 128-bit Salt | Salt used to derive the "Aura" art seeds for this circle. |
| `alias` | String | Your local nickname for the circle (e.g., "Family"). |

### 2. The `Peers` Table
Stores the hardware identities of people you've Handshaked with.
| Field | Type | Description |
| :--- | :--- | :--- |
| `peer_id` | UUID | Internal local identifier. |
| `public_key` | Curve25519 | The peer's current Hardware Public Key. |
| `callsign` | String | Their current public "Ghost" name (e.g., `Obsidian-Echo`). |
| `vue_name` | Encrypted String | Their real name, revealed after the Handshake. |
| `epoch_index` | Integer | Tracks the peer's current Identity Epoch. |

### 3. The `Circle_Members` Table (The Junction)
Maps which Peers belong to which Circles.
| Field | Type | Description |
| :--- | :--- | :--- |
| `circle_id` | UUID | Reference to `Circles`. |
| `peer_id` | UUID | Reference to `Peers`. |
| `status` | Enum | `Active`, `Retired`, or `Blocked`. |

## 🔄 Ledger Synchronization
Because there is no central server, synchronization happens **Peer-to-Peer** during active sessions.
- When two peers in the same Circle are online, they exchange **delta-updates** (encrypted with the Circle Key).
- If Bob updates his `vue_name`, Alice's ledger receives the update next time they both "see" each other on the network.

## 🛡️ Security Guarantees
- **No Global Index:** The ledger is entirely local. If Alice deletes her ledger, the "Family" circle effectively vanishes for her.
- **Hardware Bound:** The ledger cannot be backed up to iCloud in plaintext. It is only restorable via the **24-word seed**.