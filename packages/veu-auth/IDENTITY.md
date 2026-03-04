# veu-auth: Ghost Identity & Callsigns

In Veu, identity is a "Double Mirror." You are known by your true name to your Circle, but you are a mathematical ghost to the public.

## 🎭 The Public Callsign
To prevent PII (Personally Identifiable Information) leakage, every device generates a **Public Callsign**.

### 1. Generation Logic
- **Input:** The `DevicePublicKey` (stored in the Secure Enclave).
- **Transformation:** `Hash(DevicePublicKey + GlobalSalt)`.
- **Output:** A human-readable but anonymous string (e.g., `Obsidian-Echo-9`).

### 2. Properties
- **Static but Anonymous:** Your callsign stays the same so people can recognize "the artist," but it reveals nothing about your real identity.
- **Non-Searchable:** There is no "Global Directory" of callsigns. You cannot type a callsign into a search bar to find a user.

## 🔥 The Identity Burn (Rotational Identity)
Users can "Burn" their public identity at any time to break the link between their activity and their physical person.

### 1. The Evaporation
- The current `DevicePublicKey` is retired.
- A new `DevicePublicKey` is derived from the **24-word seed** using an incremented `EpochIndex`.
- The old Callsign ceases to exist on the network.

### 2. Circle Migration (The Quiet Move)
- To maintain your trusted connections, your device sends a **Migration Packet** to each Circle.
- This packet is encrypted with the **Circle Key**, so only members can see it.
- **Payload:** `Old_Callsign_Signature + New_Public_Key`.
- Your friends' ledgers update automatically. To the public, the old user is gone; the new user is a fresh ghost.

## 👤 The Private "Vue" Name
Your "Real Name" is a piece of metadata stored within the **Circle Ledger**.

### 1. Encryption
- The name is encrypted using the **Circle Symmetric Key**.
- It is never stored in plaintext on any server or IPFS node.

### 2. Mutual Reveal
- The real name is only decrypted and shown after a successful **Emerald Handshake**.
- Users can choose different "Vue Names" for different Circles (Contextual Identity).

## 🚫 Zero PII Storage
- No Phone Numbers.
- No Emails.
- No IP-to-User Mapping.
- No "Contacts" access required.