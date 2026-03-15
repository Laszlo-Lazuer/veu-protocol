// VoiceRelayTransport.swift — Veu Protocol: WebSocket fallback for voice audio
//
// Fallback audio transport when peers can't establish direct UDP connections
// (different networks, behind NAT, etc). Signaling always goes through
// GhostMessage via the mesh transport stack. This transport is ONLY used
// for encrypted audio frame forwarding when direct UDP isn't available.
// Uses Ed25519-signed registration tokens to prove device identity.

#if os(iOS)
import Foundation
import CryptoKit

/// WebSocket transport to the dedicated voice relay server.
/// Handles: registration with Ed25519 auth, signaling messages, binary audio frames.
public final class VoiceRelayTransport {

    /// Default voice relay URL.
    public static let defaultURL = URL(string: "wss://veu-voice-relay.fly.dev/ws")!

    /// Connection state.
    public enum State: Equatable {
        case disconnected
        case connecting
        case registered
        case failed(String)
    }

    @Published public private(set) var connectionState: State = .disconnected

    // Callbacks
    public var onCallOffer: ((_ callID: String, _ callerDeviceID: String, _ sdp: String?) -> Void)?
    public var onCallRinging: ((_ callID: String) -> Void)?
    public var onCallAnswer: ((_ callID: String, _ sdp: String?) -> Void)?
    public var onCallEnd: ((_ callID: String, _ reason: String) -> Void)?
    public var onAudioFrame: ((_ data: Data) -> Void)?
    public var onError: ((_ message: String) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private let relayURL: URL
    private let circleKey: SymmetricKey
    private var deviceID: String = ""
    private var circleID: String = ""
    /// The active call ID — set by VoiceCallManager so relay knows which call's frames to route.
    public var activeCallID: String?

    public init(relayURL: URL? = nil, circleKey: Data) {
        self.relayURL = relayURL ?? Self.defaultURL
        self.circleKey = SymmetricKey(data: circleKey)
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Connect & Register

    /// Connect to the voice relay and register with Ed25519-signed identity.
    public func connect(
        deviceID: String,
        circleID: String,
        signingKey: Curve25519.Signing.PrivateKey,
        pushToken: String? = nil
    ) {
        self.deviceID = deviceID
        self.circleID = circleID
        connectionState = .connecting

        let task = session.webSocketTask(with: relayURL)
        task.maximumMessageSize = 65_536
        self.webSocketTask = task
        task.resume()

        // Build signed registration token
        let timestamp = "\(Int(Date().timeIntervalSince1970))"
        let payload = "\(deviceID)|\(circleID)|\(timestamp)"
        guard let payloadData = payload.data(using: .utf8),
              let signature = try? signingKey.signature(for: payloadData) else {
            connectionState = .failed("Failed to sign registration token")
            return
        }

        let publicKey = signingKey.publicKey
        var msg: [String: Any] = [
            "type": "register",
            "device_id": deviceID,
            "circle_id": circleID,
            "public_key": publicKey.rawRepresentation.hexString,
            "timestamp": timestamp,
            "signature": Data(signature).hexString
        ]

        // Include VoIP push token if available (for offline call wakeup)
        if let pushToken = pushToken, !pushToken.isEmpty {
            msg["push_token"] = pushToken
        }

        sendJSON(msg) { [weak self] error in
            if let error = error {
                self?.connectionState = .failed("Register send failed: \(error.localizedDescription)")
                return
            }
            self?.connectionState = .registered
            self?.startReceiving()
        }
    }

    /// Disconnect from the voice relay.
    public func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
        activeCallID = nil
    }

    // MARK: - Signaling

    /// Send a call offer to a target device.
    public func sendCallOffer(callID: String, targetDeviceID: String, sdp: String? = nil) {
        activeCallID = callID
        var msg: [String: Any] = [
            "type": "call_offer",
            "call_id": callID,
            "target_device_id": targetDeviceID
        ]
        if let sdp = sdp { msg["sdp"] = sdp }
        sendJSON(msg)
    }

    /// Send a call answer.
    public func sendCallAnswer(callID: String, sdp: String? = nil) {
        var msg: [String: Any] = [
            "type": "call_answer",
            "call_id": callID
        ]
        if let sdp = sdp { msg["sdp"] = sdp }
        sendJSON(msg)
    }

    /// Send a call end.
    public func sendCallEnd(callID: String, reason: String = "user_hangup") {
        let msg: [String: Any] = [
            "type": "call_end",
            "call_id": callID,
            "reason": reason
        ]
        sendJSON(msg)
        activeCallID = nil
    }

    // MARK: - Audio Frames

    /// Send an encrypted audio frame via the relay.
    /// Frame format: [36-byte ASCII call_id][AES-GCM(seq + compressed audio)]
    public func sendAudioFrame(_ frame: Data) {
        guard let callID = activeCallID,
              let task = webSocketTask else { return }

        do {
            let sealedBox = try AES.GCM.seal(frame, using: circleKey)
            guard let encrypted = sealedBox.combined else { return }

            // Prefix with 36-byte ASCII call ID for relay routing
            var packet = Data(callID.utf8.prefix(36))
            // Pad to exactly 36 bytes if needed
            while packet.count < 36 { packet.append(0) }
            packet.append(encrypted)

            task.send(.data(packet)) { error in
                if let error = error {
                    print("[VoiceRelay] ⚠️ Audio send error: \(error)")
                }
            }
        } catch {
            print("[VoiceRelay] ⚠️ Encryption error: \(error)")
        }
    }

    // MARK: - Receive Loop

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleSignalingMessage(text)
                case .data(let data):
                    self.handleBinaryFrame(data)
                @unknown default:
                    break
                }
                self.startReceiving() // Continue listening
            case .failure(let error):
                print("[VoiceRelay] WebSocket receive error: \(error)")
                self.connectionState = .disconnected
            }
        }
    }

    private func handleSignalingMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "call_offer":
            let callID = json["call_id"] as? String ?? ""
            let callerDeviceID = json["caller_device_id"] as? String ?? ""
            let sdp = json["sdp"] as? String
            activeCallID = callID
            onCallOffer?(callID, callerDeviceID, sdp)

        case "call_ringing":
            let callID = json["call_id"] as? String ?? ""
            onCallRinging?(callID)

        case "call_push_sent":
            // Server sent a VoIP push to wake offline callee; treat as ringing
            let callID = json["call_id"] as? String ?? ""
            print("[VoiceRelay] 📲 Push sent to wake callee for call \(callID.prefix(8))")
            onCallRinging?(callID)

        case "call_answer":
            let callID = json["call_id"] as? String ?? ""
            let sdp = json["sdp"] as? String
            onCallAnswer?(callID, sdp)

        case "call_end":
            let callID = json["call_id"] as? String ?? ""
            let reason = json["reason"] as? String ?? "unknown"
            activeCallID = nil
            onCallEnd?(callID, reason)

        case "error":
            let message = json["message"] as? String ?? "unknown error"
            print("[VoiceRelay] ❌ Server error: \(message)")
            onError?(message)

        default:
            print("[VoiceRelay] Unknown message type: \(type)")
        }
    }

    private func handleBinaryFrame(_ data: Data) {
        guard data.count > 36 else { return }

        // Strip 36-byte call ID prefix, decrypt the rest
        let encrypted = data.subdata(in: 36..<data.count)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
            let decrypted = try AES.GCM.open(sealedBox, using: circleKey)
            onAudioFrame?(decrypted)
        } catch {
            // Silently drop undecryptable frames (could be from stale session)
        }
    }

    // MARK: - Helpers

    private func sendJSON(_ dict: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            completion?(NSError(domain: "VoiceRelay", code: -1))
            return
        }
        task.send(.string(text), completionHandler: completion ?? { _ in })
    }
}

// MARK: - Data Hex Extension

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#endif
