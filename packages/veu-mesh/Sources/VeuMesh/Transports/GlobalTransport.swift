// GlobalTransport.swift — Veu Protocol: WebSocket Relay Transport
//
// Connects to a self-hosted veu-relay server over WebSocket for global
// artifact sync.  All payloads are AES-256-GCM encrypted — the relay
// is completely blind.

import Foundation
import VeuGhost

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// WebSocket relay transport for global (internet) artifact sync.
///
/// Connects to a `veu-relay` server, subscribes to a circle's topic,
/// and exchanges encrypted artifacts.  The relay server only sees
/// encrypted blobs and topic hashes — it is completely blind.
public final class GlobalTransport: MeshTransportProtocol {

    /// Must match the relay server's maxMessageSize (10 MB).
    private static let maxMessageSize = 10 * 1024 * 1024

    // MARK: - MeshTransportProtocol

    public let name = "Global"
    public private(set) var state: MeshTransportState = .disconnected
    public weak var delegate: (any MeshTransportDelegate)?

    public var isAvailable: Bool {
        state == .connected
    }

    // MARK: - Configuration

    /// The relay server WebSocket URL (e.g., `wss://relay.example.com/ws`).
    public let relayURL: URL

    /// The Circle's topic hash for channel subscription.
    public let topicHash: String

    /// The Circle's symmetric key for envelope encryption.
    private let circleKey: Data

    /// Optional APNs push token to register with the relay.
    public var pushToken: String?

    /// Device ID for push token registration.
    public let deviceID: String

    // MARK: - Internal

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var relayConnection: RelayTransportConnection?
    private var reconnectAttempt = 0
    private var maxReconnectDelay: TimeInterval = 60
    private var isReconnecting = false
    private var lastConnectedTime: Int = Int(Date().timeIntervalSince1970)

    /// Create a GlobalTransport for a Circle.
    ///
    /// - Parameters:
    ///   - relayURL: The relay server base URL.
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - deviceID: This device's unique ID.
    public init(relayURL: URL, circleKey: Data, deviceID: String) {
        self.relayURL = relayURL
        self.circleKey = circleKey
        self.topicHash = GhostConnection.circleTopicHash(circleKey: circleKey)
        self.deviceID = deviceID
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard state != .connected else { return }
        state = .connecting
        delegate?.transport(self, didChangeState: .connecting)

        // Build WebSocket URL with topic query parameter
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "topic", value: topicHash))
        components?.queryItems = queryItems

        guard let wsURL = components?.url else {
            throw VeuMeshError.configurationError("Invalid relay URL")
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: wsURL)
        task.maximumMessageSize = Self.maxMessageSize
        self.urlSession = session
        self.webSocketTask = task

        task.resume()
        reconnectAttempt = 0
        state = .connecting
        delegate?.transport(self, didChangeState: .connecting)

        // Create the virtual connection
        let conn = RelayTransportConnection(
            webSocketTask: task,
            circleKey: circleKey,
            topicHash: topicHash,
            endpointDesc: "relay:\(relayURL.host ?? "unknown")"
        )
        conn.onRelayDeliveryUpdate = { [weak self] update in
            guard let self = self else { return }
            self.delegate?.transport(self, didUpdateRelayDelivery: update)
        }
        self.relayConnection = conn
        delegate?.transport(self, didConnectPeer: conn)

        // Register push token if available
        registerPushTokenIfNeeded()

        // Pull any stored artifacts from the relay
        pullMissedArtifacts()

        // Start listening for messages
        listenForMessages()
    }

    public func stop() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        relayConnection = nil
        state = .disconnected
        delegate?.transport(self, didChangeState: .disconnected)
    }

    // MARK: - Push Token Registration

    private func registerPushTokenIfNeeded() {
        guard let token = pushToken, let task = webSocketTask else { return }
        let msg = RelayMessage.registerToken(
            RelayMessage.RegisterTokenPayload(topic: topicHash, token: token, deviceID: deviceID)
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        task.send(.string(String(data: data, encoding: .utf8) ?? "")) { _ in }
    }

    // MARK: - WebSocket Message Loop

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .connecting = self.state {
                    self.state = .connected
                    self.delegate?.transport(self, didChangeState: .connected)
                }
                self.handleWebSocketMessage(message)
                self.listenForMessages()

            case .failure(let error):
                print("[GlobalTransport] WebSocket error: \(error)")
                self.state = .failed(error.localizedDescription)
                self.delegate?.transport(self, didChangeState: self.state)
                self.scheduleReconnect()
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            if let relayMsg = try? JSONDecoder().decode(RelayMessage.self, from: data) {
                handleRelayMessage(relayMsg)
            }

        case .data(let data):
            if let relayMsg = try? JSONDecoder().decode(RelayMessage.self, from: data) {
                handleRelayMessage(relayMsg)
            }

        @unknown default:
            break
        }
    }

    private func handleRelayMessage(_ message: RelayMessage) {
        switch message {
        case .artifactNotify(let payload):
            // Decode the base64 payload back to encrypted data and enqueue
            if let encryptedData = Data(base64Encoded: payload.payload) {
                relayConnection?.enqueueReceived(encryptedData)
            }

        case .pullResponse(let payload):
            // Process each artifact in the pull response
            for artifact in payload.artifacts {
                if let encryptedData = Data(base64Encoded: artifact.payload) {
                    relayConnection?.enqueueReceived(encryptedData)
                }
            }

        case .artifactAck(let payload):
            relayConnection?.handleRelayAck(payload)

        default:
            break
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)

        print("[GlobalTransport] Scheduling reconnect #\(reconnectAttempt) in \(delay)s")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.isReconnecting = false
            do {
                try self.start()
                self.pullMissedArtifacts()
            } catch {
                print("[GlobalTransport] Reconnect failed: \(error)")
            }
        }
    }

    /// Pull artifacts stored on the relay since we last connected.
    private func pullMissedArtifacts() {
        guard let task = webSocketTask else { return }
        let pullMsg = RelayMessage.pullRequest(
            RelayMessage.PullRequestPayload(topic: topicHash, since: lastConnectedTime)
        )
        guard let data = try? JSONEncoder().encode(pullMsg),
              let json = String(data: data, encoding: .utf8) else { return }
        print("[GlobalTransport] Pulling missed artifacts since \(lastConnectedTime)")
        task.send(.string(json)) { error in
            if let error = error {
                print("[GlobalTransport] Pull request failed: \(error)")
            }
        }
        lastConnectedTime = Int(Date().timeIntervalSince1970)
    }
}

// MARK: - Relay Wire Protocol Messages

/// Messages exchanged between the relay client and server.
public enum RelayMessage: Codable {
    case artifactPush(ArtifactPushPayload)
    case artifactAck(ArtifactAckPayload)
    case pullRequest(PullRequestPayload)
    case pullResponse(PullResponsePayload)
    case registerToken(RegisterTokenPayload)
    case artifactNotify(ArtifactNotifyPayload)

    public struct ArtifactPushPayload: Codable {
        public var cid: String
        public var topic: String
        public var payload: String // base64-encoded encrypted blob
        public var persist: Bool?
        public var burnAfter: Int?

        private enum CodingKeys: String, CodingKey {
            case cid, topic, payload, persist
            case burnAfter = "burn_after"
        }

        public init(cid: String, topic: String, payload: String, persist: Bool? = nil, burnAfter: Int? = nil) {
            self.cid = cid
            self.topic = topic
            self.payload = payload
            self.persist = persist
            self.burnAfter = burnAfter
        }
    }

    public struct ArtifactAckPayload: Codable {
        public enum Status: String, Codable {
            case accepted
            case duplicate
            case rejected
        }

        public var cid: String
        public var topic: String
        public var status: Status
        public var message: String?

        public init(cid: String, topic: String, status: Status, message: String? = nil) {
            self.cid = cid
            self.topic = topic
            self.status = status
            self.message = message
        }
    }

    public struct PullRequestPayload: Codable {
        public var topic: String
        public var since: Int // Unix timestamp

        public init(topic: String, since: Int) {
            self.topic = topic
            self.since = since
        }
    }

    public struct PullResponsePayload: Codable {
        public struct Artifact: Codable {
            public var cid: String
            public var payload: String
            public var timestamp: Int
        }
        public var artifacts: [Artifact]
    }

    public struct RegisterTokenPayload: Codable {
        public var topic: String
        public var token: String
        public var deviceID: String

        public init(topic: String, token: String, deviceID: String) {
            self.topic = topic
            self.token = token
            self.deviceID = deviceID
        }
    }

    public struct ArtifactNotifyPayload: Codable {
        public var cid: String
        public var topic: String
        public var payload: String
    }

    // MARK: - Coding Keys

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let singleContainer = try decoder.singleValueContainer()

        switch type {
        case "artifact_push": self = .artifactPush(try singleContainer.decode(ArtifactPushPayload.self))
        case "artifact_ack": self = .artifactAck(try singleContainer.decode(ArtifactAckPayload.self))
        case "pull_request": self = .pullRequest(try singleContainer.decode(PullRequestPayload.self))
        case "pull_response": self = .pullResponse(try singleContainer.decode(PullResponsePayload.self))
        case "register_token": self = .registerToken(try singleContainer.decode(RegisterTokenPayload.self))
        case "artifact_notify": self = .artifactNotify(try singleContainer.decode(ArtifactNotifyPayload.self))
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown type: \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .artifactPush(let p):
            try container.encode("artifact_push", forKey: .type)
            try p.encode(to: encoder)
        case .artifactAck(let p):
            try container.encode("artifact_ack", forKey: .type)
            try p.encode(to: encoder)
        case .pullRequest(let p):
            try container.encode("pull_request", forKey: .type)
            try p.encode(to: encoder)
        case .pullResponse(let p):
            try container.encode("pull_response", forKey: .type)
            try p.encode(to: encoder)
        case .registerToken(let p):
            try container.encode("register_token", forKey: .type)
            try p.encode(to: encoder)
        case .artifactNotify(let p):
            try container.encode("artifact_notify", forKey: .type)
            try p.encode(to: encoder)
        }
    }
}
