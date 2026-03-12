// RelayTransportConnection.swift — Veu Protocol: WebSocket Relay Transport Connection
//
// Adapts a URLSessionWebSocketTask into a TransportConnection for use
// by the sync layer.  Sends GhostMessages over the relay as encrypted
// base64 blobs wrapped in RelayMessage JSON.

import Foundation
import VeuGhost

/// A transport connection over a WebSocket relay server.
///
/// Conforms to `TransportConnection` so the `SyncEngine` can send/receive
/// `GhostMessage`s through the relay without knowing the underlying transport.
public final class RelayTransportConnection: TransportConnection, @unchecked Sendable {

    public let endpointDescription: String

    private let webSocketTask: URLSessionWebSocketTask
    private let circleKey: Data
    private let topicHash: String

    /// Queue of received encrypted data waiting for `receive()` calls.
    private var receiveQueue: [Data] = []
    private var pendingReceive: ((Result<GhostMessage, VeuGhostError>) -> Void)?
    private let lock = NSLock()

    init(webSocketTask: URLSessionWebSocketTask, circleKey: Data, topicHash: String, endpointDesc: String) {
        self.webSocketTask = webSocketTask
        self.circleKey = circleKey
        self.topicHash = topicHash
        self.endpointDescription = endpointDesc
    }

    // MARK: - TransportConnection

    public func send(_ message: GhostMessage, completion: @escaping (Result<Void, VeuGhostError>) -> Void) {
        do {
            let envelope = try message.seal(with: circleKey)
            let base64 = envelope.base64EncodedString()

            // Validate against relay's 5MB payload limit
            if base64.utf8.count > 4_500_000 {
                print("[GlobalTransport] ⚠️ Payload too large for relay (\(base64.utf8.count / 1024)KB), skipping")
                completion(.failure(.connectionFailed("Payload too large for relay (\(base64.utf8.count / 1024)KB)")))
                return
            }

            // Wrap in relay protocol message
            let cid = extractCID(from: message) ?? "sync"
            let relayMsg = RelayMessage.artifactPush(
                RelayMessage.ArtifactPushPayload(cid: cid, topic: topicHash, payload: base64)
            )
            let jsonData = try JSONEncoder().encode(relayMsg)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                completion(.failure(.encryptionFailed("Failed to encode relay message")))
                return
            }

            print("[GlobalTransport] Sending \(jsonData.count / 1024)KB via relay (cid: \(cid))")
            webSocketTask.send(.string(jsonString)) { error in
                if let error = error {
                    print("[GlobalTransport] ❌ Send failed: \(error)")
                    completion(.failure(.connectionFailed(error.localizedDescription)))
                } else {
                    print("[GlobalTransport] ✅ Sent \(cid) via relay")
                    completion(.success(()))
                }
            }
        } catch let error as VeuGhostError {
            completion(.failure(error))
        } catch {
            completion(.failure(.encryptionFailed(error.localizedDescription)))
        }
    }

    public func receive(completion: @escaping (Result<GhostMessage, VeuGhostError>) -> Void) {
        lock.lock()
        if let data = receiveQueue.first {
            receiveQueue.removeFirst()
            lock.unlock()
            decodeEnvelope(data, completion: completion)
        } else {
            pendingReceive = completion
            lock.unlock()
        }
    }

    public func cancel() {
        webSocketTask.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Internal

    /// Called by GlobalTransport when a message arrives for this connection.
    func enqueueReceived(_ encryptedData: Data) {
        lock.lock()
        if let pending = pendingReceive {
            pendingReceive = nil
            lock.unlock()
            decodeEnvelope(encryptedData, completion: pending)
        } else {
            receiveQueue.append(encryptedData)
            lock.unlock()
        }
    }

    private func decodeEnvelope(_ data: Data, completion: @escaping (Result<GhostMessage, VeuGhostError>) -> Void) {
        do {
            let message = try GhostMessage.open(envelope: data, with: circleKey)
            completion(.success(message))
        } catch let error as VeuGhostError {
            completion(.failure(error))
        } catch {
            completion(.failure(.decodingFailed(error.localizedDescription)))
        }
    }

    private func extractCID(from message: GhostMessage) -> String? {
        switch message {
        case .artifactPush(let p): return p.cid
        case .burnNotice(let p): return p.cid
        case .ack(let p): return p.cid
        default: return nil
        }
    }
}
