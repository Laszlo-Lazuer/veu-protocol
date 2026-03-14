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
    public var transportName: String = "Global"

    struct PendingSend {
        let deliveryCID: String?
        let completion: (Result<Void, VeuGhostError>) -> Void
    }

    private let webSocketTask: URLSessionWebSocketTask
    private let circleKey: Data
    private let topicHash: String
    private let relayAckTimeout: TimeInterval = 10

    /// Queue of received encrypted data waiting for `receive()` calls.
    private var receiveQueue: [Data] = []
    private var pendingReceive: ((Result<GhostMessage, VeuGhostError>) -> Void)?
    private var pendingSendAcks: [String: PendingSend] = [:]
    private let lock = NSLock()

    var onRelayDeliveryUpdate: ((RelayDeliveryUpdate) -> Void)?

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
            let metadata = relayMetadata(for: message)
            let payloadSize = RelayTransportEnvelope.encodedPayloadSize(for: envelope)
            let packageSize = RelayTransportEnvelope.encodedPackageSize(
                for: envelope,
                cid: metadata.relayCID,
                topic: topicHash,
                persist: metadata.persist
            )

            if payloadSize > RelayTransportEnvelope.maxPayloadSize {
                completion(.failure(.connectionFailed("Payload too large for relay (\(payloadSize / 1024)KB)")))
                return
            }

            if packageSize > RelayTransportEnvelope.maxMessageSize {
                completion(.failure(.connectionFailed("Encoded relay package exceeds websocket limit")))
                return
            }

            let relayMsg = RelayMessage.artifactPush(
                RelayMessage.ArtifactPushPayload(
                    cid: metadata.relayCID,
                    topic: topicHash,
                    payload: envelope.base64EncodedString(),
                    persist: metadata.persist,
                    burnAfter: metadata.burnAfter
                )
            )
            let jsonData = try JSONEncoder().encode(relayMsg)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                completion(.failure(.encryptionFailed("Failed to encode relay message")))
                return
            }

            lock.lock()
            pendingSendAcks[metadata.relayCID] = PendingSend(deliveryCID: metadata.deliveryCID, completion: completion)
            lock.unlock()
            scheduleAckTimeout(for: metadata.relayCID)

            print("[GlobalTransport] Sending \(jsonData.count / 1024)KB via relay (cid: \(metadata.relayCID))")
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error = error {
                    self?.completePendingSend(
                        relayCID: metadata.relayCID,
                        result: .failure(.connectionFailed(error.localizedDescription)),
                        update: nil
                    )
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
        failAllPendingSends(with: .connectionFailed("Relay connection closed"))
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

    func handleRelayAck(_ payload: RelayMessage.ArtifactAckPayload) {
        let status: RelayDeliveryUpdate.Status
        let result: Result<Void, VeuGhostError>

        switch payload.status {
        case .accepted:
            status = .accepted
            result = .success(())
        case .duplicate:
            status = .duplicate
            result = .success(())
        case .rejected:
            status = .rejected
            result = .failure(.connectionFailed(payload.message ?? "Relay rejected message"))
        }

        let update = pendingDeliveryUpdate(relayCID: payload.cid, status: status, detail: payload.message)
        completePendingSend(relayCID: payload.cid, result: result, update: update)
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

    private func relayMetadata(for message: GhostMessage) -> (relayCID: String, persist: Bool, deliveryCID: String?, burnAfter: Int?) {
        switch message {
        case .artifactPush(let payload):
            return (payload.cid, true, payload.cid, payload.burnAfter)
        case .burnNotice(let payload):
            return ("burn-\(payload.cid)", true, nil, nil)
        case .syncRequest:
            return ("sync-request-\(UUID().uuidString)", false, nil, nil)
        case .syncResponse:
            return ("sync-response-\(UUID().uuidString)", false, nil, nil)
        case .ack(let payload):
            return ("ack-\(payload.cid)-\(UUID().uuidString)", false, nil, nil)
        case .voiceCall(let payload):
            return ("voice-\(payload.callID)-\(UUID().uuidString)", false, nil, nil)
        }
    }

    private func scheduleAckTimeout(for relayCID: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + relayAckTimeout) { [weak self] in
            self?.completePendingSend(relayCID: relayCID, result: .failure(.timeout), update: nil)
        }
    }

    private func pendingDeliveryUpdate(relayCID: String, status: RelayDeliveryUpdate.Status, detail: String?) -> RelayDeliveryUpdate? {
        lock.lock()
        let deliveryCID = pendingSendAcks[relayCID]?.deliveryCID
        lock.unlock()
        guard let deliveryCID else { return nil }
        return RelayDeliveryUpdate(cid: deliveryCID, status: status, detail: detail)
    }

    private func completePendingSend(relayCID: String, result: Result<Void, VeuGhostError>, update: RelayDeliveryUpdate?) {
        lock.lock()
        let pending = pendingSendAcks.removeValue(forKey: relayCID)
        lock.unlock()

        guard let pending else { return }
        if let update {
            onRelayDeliveryUpdate?(update)
        }
        pending.completion(result)
    }

    private func failAllPendingSends(with error: VeuGhostError) {
        lock.lock()
        let pending = Array(pendingSendAcks.values)
        pendingSendAcks.removeAll()
        lock.unlock()

        for item in pending {
            item.completion(.failure(error))
        }
    }
}
