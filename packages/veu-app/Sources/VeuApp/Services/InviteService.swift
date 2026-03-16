import Foundation
import VeuAuth
import VeuCrypto
import VeuMesh

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Invite Phase

public enum InvitePhase: Equatable {
    case idle
    case depositing
    case waitingForClaim
    case claiming
    case verifying
    case confirmed
    case failed(String)
    case expired
}

// MARK: - Invite Payload

/// Public offer carried inside the relay invite blob.
struct InviteOfferPayload: Codable {
    let publicKey: String   // base64 X25519 public key
    let circleID: String
    let hasExistingKey: Bool?  // true when inviter is adding to existing circle
}

// MARK: - InviteService

/// Manages the full lifecycle of a single-use relay-mediated invite.
///
/// **Inviter flow**: `generateInvite` → share link → wait → SAS verify → `confirm`
/// **Invitee flow**: `claimInvite` → SAS verify → `confirm`
public final class InviteService: ObservableObject {

    // MARK: Published State

    @Published public private(set) var phase: InvitePhase = .idle
    @Published public private(set) var shortCode: String?
    @Published public private(set) var auraColorHex: String?
    @Published public private(set) var inviteLink: String?
    @Published public private(set) var circleID: String?

    /// The peer's X25519 public key data, available after key exchange.
    public var peerPublicKeyData: Data? { handshakeSession?.peerPublicKeyData }

    /// The circle key to use after confirmation.
    /// Returns the transferred existing key (multi-member) or the ECDH-derived key (new circle).
    public var circleKey: CircleKey? { transferredCircleKey ?? handshakeSession?.circleKey }

    /// When set by the coordinator, the inviter will transfer this existing key
    /// to the invitee instead of both using the ECDH-derived key.
    public var existingCircleKey: CircleKey?

    // MARK: Private State

    private var handshakeSession: HandshakeSession?
    private var transferredCircleKey: CircleKey?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var token: String?
    private let relayURL: URL
    private var localKeypairForInvitee: EphemeralKeypair?
    private var expectingKeyTransfer = false

    // MARK: Init

    public init(relayURL: URL = RelayDefaults.defaultRelayURL) {
        self.relayURL = relayURL
    }

    // MARK: - Inviter Flow

    /// Generate an invite link for an existing circle.
    ///
    /// Deposits the offer on the relay, then listens on the rendezvous topic
    /// for the invitee's key-exchange response.
    public func generateInvite(circleID: String, expiresIn: Int = 86400) async throws {
        guard case .idle = phase else { return }
        self.circleID = circleID
        self.phase = .depositing

        // 1. Create handshake session and initiate (generates X25519 keypair)
        let session = HandshakeSession(circleID: circleID)
        try session.initiate()
        self.handshakeSession = session

        guard let publicKeyData = session.deadLink?.publicKey.rawRepresentation else {
            self.phase = .failed("Failed to generate keypair")
            return
        }

        // 2. Build invite payload (public keys + circleID)
        let offer = InviteOfferPayload(
            publicKey: publicKeyData.base64EncodedString(),
            circleID: circleID,
            hasExistingKey: existingCircleKey != nil ? true : nil
        )
        let payloadData = try JSONEncoder().encode(offer)
        let payloadString = payloadData.base64EncodedString()

        // 3. Generate token and connect to rendezvous topic
        let inviteToken = UUID().uuidString.lowercased()
        self.token = inviteToken
        let topicHash = GlobalTransport.inviteTopicHash(token: inviteToken)

        try connectWebSocket(topicHash: topicHash)

        // 4. Deposit invite on relay
        let deposit = RelayMessage.inviteDeposit(
            RelayMessage.InviteDepositPayload(
                token: inviteToken,
                payload: payloadString,
                expiresIn: expiresIn
            )
        )
        try await sendRelayMessage(deposit)

        // 5. Set invite link and begin listening
        self.inviteLink = "veu://invite?id=\(inviteToken)"
        self.phase = .waitingForClaim
        listenForMessages()
    }

    // MARK: - Invitee Flow

    /// Claim an invite by token (from deep link).
    ///
    /// Sends the claim, receives the offer payload, completes the key
    /// exchange, and pushes our public key back to the rendezvous topic.
    public func claimInvite(token: String) async throws {
        guard case .idle = phase else { return }
        self.token = token
        phase = .claiming

        let topicHash = GlobalTransport.inviteTopicHash(token: token)
        try connectWebSocket(topicHash: topicHash)

        let claim = RelayMessage.inviteClaim(
            RelayMessage.InviteClaimPayload(token: token)
        )
        try await sendRelayMessage(claim)
        listenForMessages()
    }

    // MARK: - Verification

    /// Confirm the handshake after SAS code verification.
    public func confirm() throws {
        guard let session = handshakeSession, session.phase == .verifying else {
            throw InviteError.invalidState
        }
        try session.confirm()
        phase = .confirmed
        disconnect()
    }

    /// Reject the handshake and tear down the connection.
    public func reject() {
        handshakeSession?.reject()
        disconnect()
        reset()
    }

    /// Reset all state to idle.
    public func reset() {
        handshakeSession = nil
        transferredCircleKey = nil
        existingCircleKey = nil
        expectingKeyTransfer = false
        disconnect()
        token = nil
        circleID = nil
        shortCode = nil
        auraColorHex = nil
        inviteLink = nil
        localKeypairForInvitee = nil
        phase = .idle
    }

    // MARK: - WebSocket Management

    private func connectWebSocket(topicHash: String) throws {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "topic", value: topicHash))
        components?.queryItems = queryItems

        guard let wsURL = components?.url else {
            throw InviteError.invalidRelayURL
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: wsURL)
        task.resume()

        self.urlSession = session
        self.webSocketTask = task
    }

    private func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func sendRelayMessage(_ message: RelayMessage) async throws {
        guard let task = webSocketTask else {
            throw InviteError.notConnected
        }
        let data = try JSONEncoder().encode(message)
        guard let json = String(data: data, encoding: .utf8) else {
            throw InviteError.encodingFailed
        }
        try await task.send(.string(json))
    }

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let message):
                    self.handleWebSocketMessage(message)
                    self.listenForMessages()
                case .failure(let error):
                    if case .idle = self.phase { return }
                    if case .confirmed = self.phase { return }
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let d = text.data(using: .utf8) else { return }
            data = d
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        guard let relayMsg = try? JSONDecoder().decode(RelayMessage.self, from: data) else {
            return
        }

        switch relayMsg {
        case .inviteAck(let ack):
            handleInviteAck(ack)
        case .inviteData(let inviteData):
            handleInviteData(inviteData)
        case .artifactNotify(let notify):
            handleArtifactNotify(notify)
        default:
            break
        }
    }

    // MARK: - Message Handlers

    /// Inviter receives ack after deposit.
    private func handleInviteAck(_ ack: RelayMessage.InviteAckPayload) {
        if ack.status != "accepted" {
            phase = .failed(ack.message ?? "Invite rejected by relay")
        }
    }

    /// Invitee receives invite data after claim.
    private func handleInviteData(_ payload: RelayMessage.InviteDataPayload) {
        do {
            guard let payloadData = Data(base64Encoded: payload.payload) else {
                phase = .failed("Invalid invite payload")
                return
            }
            let offer = try JSONDecoder().decode(InviteOfferPayload.self, from: payloadData)
            guard let remotePublicKeyData = Data(base64Encoded: offer.publicKey) else {
                phase = .failed("Invalid public key in invite")
                return
            }

            self.circleID = offer.circleID
            self.expectingKeyTransfer = offer.hasExistingKey == true

            // Create handshake session for invitee and perform key exchange
            let session = HandshakeSession(circleID: offer.circleID)
            let keypair = EphemeralKeypair.generate()
            self.localKeypairForInvitee = keypair

            try session.respondDirect(
                remotePublicKeyData: remotePublicKeyData,
                localKeypair: keypair
            )

            self.handshakeSession = session
            self.shortCode = session.shortCode
            self.auraColorHex = session.auraColorHex
            phase = .verifying

            // Push our public key to rendezvous topic for the inviter
            Task {
                try await pushResponseArtifact(
                    publicKeyData: keypair.publicKey.rawRepresentation
                )
            }
        } catch {
            phase = .failed("Failed to process invite: \(error.localizedDescription)")
        }
    }

    /// Inviter receives invitee's public key via artifact on rendezvous topic.
    /// Also handles key-transfer notifications on the invitee side.
    private func handleArtifactNotify(_ notify: RelayMessage.ArtifactNotifyPayload) {
        // Key transfer: invitee receives existing circle key from inviter
        if notify.cid.hasPrefix("key-transfer:"), case .verifying = phase {
            decryptKeyTransfer(payload: notify.payload)
            return
        }

        guard case .waitingForClaim = phase else { return }

        guard let remotePublicKeyData = Data(base64Encoded: notify.payload) else {
            return
        }

        // Ignore our own key echoed back
        if let deadLink = handshakeSession?.deadLink,
           remotePublicKeyData == deadLink.publicKey.rawRepresentation {
            return
        }

        do {
            try handshakeSession?.receiveResponse(remotePublicKeyData: remotePublicKeyData)
            self.shortCode = handshakeSession?.shortCode
            self.auraColorHex = handshakeSession?.auraColorHex
            phase = .verifying

            // After ECDH, transfer existing circle key if adding to existing circle
            if let existingKey = existingCircleKey,
               let ecdhKey = handshakeSession?.circleKey {
                Task { [weak self] in
                    try await self?.pushKeyTransfer(existingKey: existingKey, ecdhKey: ecdhKey)
                }
            }
        } catch {
            phase = .failed("Key exchange failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Key Transfer (Multi-Member Circles)

    /// Encrypt the existing circle key with the ECDH-derived key and push to relay.
    private func pushKeyTransfer(existingKey: CircleKey, ecdhKey: CircleKey) async throws {
        guard let token = token else { return }
        let topicHash = GlobalTransport.inviteTopicHash(token: token)

        // Serialize: keyData (32 bytes) + glazeSalt (16 bytes)
        let plaintext = existingKey.keyData + existingKey.glazeSalt

        // Encrypt with AES-GCM using the ECDH-derived key
        let sealedBox = try AES.GCM.seal(plaintext, using: ecdhKey.symmetricKey)
        guard let combined = sealedBox.combined else { return }

        let artifact = RelayMessage.artifactPush(
            RelayMessage.ArtifactPushPayload(
                cid: "key-transfer:\(UUID().uuidString)",
                topic: topicHash,
                payload: combined.base64EncodedString(),
                persist: false
            )
        )
        try await sendRelayMessage(artifact)
    }

    /// Decrypt a key-transfer artifact and store the transferred circle key.
    private func decryptKeyTransfer(payload: String) {
        guard let ecdhKey = handshakeSession?.circleKey,
              let encryptedData = Data(base64Encoded: payload) else { return }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let plaintext = try AES.GCM.open(sealedBox, using: ecdhKey.symmetricKey)

            guard plaintext.count == 48 else { return } // 32 key + 16 salt
            let keyData = Data(plaintext.prefix(32))
            let glazeSalt = Data(plaintext.suffix(16))
            self.transferredCircleKey = CircleKey(keyData: keyData, glazeSalt: glazeSalt)
        } catch {
            print("[InviteService] Key transfer decrypt failed: \(error)")
        }
    }

    /// Invitee pushes their public key as an artifact on the rendezvous topic.
    private func pushResponseArtifact(publicKeyData: Data) async throws {
        guard let token = token else { return }
        let topicHash = GlobalTransport.inviteTopicHash(token: token)
        let artifact = RelayMessage.artifactPush(
            RelayMessage.ArtifactPushPayload(
                cid: UUID().uuidString,
                topic: topicHash,
                payload: publicKeyData.base64EncodedString(),
                persist: false
            )
        )
        try await sendRelayMessage(artifact)
    }
}

// MARK: - Errors

public enum InviteError: Error, LocalizedError {
    case invalidState
    case invalidRelayURL
    case notConnected
    case encodingFailed
    case expired
    case alreadyClaimed

    public var errorDescription: String? {
        switch self {
        case .invalidState: return "Invalid invite state"
        case .invalidRelayURL: return "Invalid relay URL"
        case .notConnected: return "Not connected to relay"
        case .encodingFailed: return "Failed to encode message"
        case .expired: return "Invite has expired"
        case .alreadyClaimed: return "Invite has already been claimed"
        }
    }
}
