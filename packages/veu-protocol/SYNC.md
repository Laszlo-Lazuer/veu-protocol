# veu-protocol: Circle Sync (The Ghost Network)

Veu has no central server to coordinate communication. Instead, it uses a **Decentralized Multi-Transport Layer** to ensure that "Islands" (Circles) can sync data securely and anonymously.

## 📡 The Transport Hierarchy

The protocol attempts to sync data using the most private and direct method available, falling back to broader networks only when necessary.

### 1. The Local Pulse (mDNS & Bluetooth LE)
When members of a Circle are in physical proximity (same Wi-Fi or within Bluetooth range).
- **Mechanism:** Devices broadcast an encrypted "Pulse" packet.
- **Privacy:** The broadcast contains no PII. Only a peer with the **Circle Key** can decrypt the pulse and recognize that a "Friend" is nearby.
- **Speed:** Near-instantaneous peer-to-peer sync.

### 2. The Global Mesh (libp2p & IPFS)
When peers are not in physical proximity.
- **DHT Routing:** Veu uses a Kademlia Distributed Hash Table (DHT) to find peers. 
- **Topic PubSub:** Each Circle exists as a unique, encrypted PubSub topic: `Hash(Circle_Key + Global_Salt)`.
- **Relays:** If both peers are behind restrictive NATs, the protocol uses **Circuit Relays** to hop through intermediate nodes without exposing the payload (which remains E2EE).

## 🔄 The Delta-Sync Logic (The Ledger Update)

To minimize data usage and maintain a "Zero-Knowledge" state, Veu uses a **Vector Clock** based synchronization.

### 1. The State Vector
Every device maintains a local `StateVector` for each Circle: `{PeerID: Last_Known_Sequence_Number}`.

### 2. The Exchange
- **The Handshake:** Alice and Bob exchange State Vectors.
- **The Delta:** Alice sees that Bob is missing messages 45-50. She encrypts those specific artifacts and sends them directly to him.
- **The Merge:** Bob decrypts the artifacts, updates his local **Circle Ledger**, and increments his State Vector.

## 🛡️ Anti-Tracking Measures

### 1. IP Obfuscation
Veu prioritizes connections over the **Tor Network** or **I2P** for global mesh sync to hide the physical IP addresses of the peers.

### 2. Traffic Padding
To prevent "Traffic Analysis" (where an ISP could guess you are using Veu by looking at packet sizes), the protocol injects random **Chaff Packets** into the stream to make all communication look like uniform noise.

### 3. Ephemeral Peer IDs
Libp2p Peer IDs are rotated every time the user performs an **Identity Burn**, ensuring that your network presence cannot be linked across different identity epochs.

## 🚫 No Global Discovery
There is no way to "Search for a Peer" or "Join a Global Channel." If you do not have the **Circle Key**, the network traffic is mathematically indistinguishable from background radiation.