// MeshPeerConnection.swift — Veu Protocol: MultipeerConnectivity Transport Connection
//
// Wraps an MCSession peer into a TransportConnection for use by the sync layer.
// Messages are encrypted with AES-256-GCM (Circle Key) before sending over MC.

import Foundation
import MultipeerConnectivity
import VeuGhost

/// A transport connection over MultipeerConnectivity (Bluetooth LE / AWDL).
///
/// Conforms to `TransportConnection` so the `SyncEngine` can send/receive
/// `GhostMessage`s over Bluetooth mesh without knowing the underlying transport.
public final class MeshPeerConnection: TransportConnection, @unchecked Sendable {

    public var endpointDescription: String {
        peerID.displayName
    }

    private let session: MCSession
    private let peerID: MCPeerID
    private let circleKey: Data

    /// Queue of received data waiting for `receive()` calls.
    private var receiveQueue: [Data] = []
    private var pendingReceive: ((Result<GhostMessage, VeuGhostError>) -> Void)?
    private let lock = NSLock()

    init(session: MCSession, peerID: MCPeerID, circleKey: Data) {
        self.session = session
        self.peerID = peerID
        self.circleKey = circleKey
    }

    // MARK: - TransportConnection

    public func send(_ message: GhostMessage, completion: @escaping (Result<Void, VeuGhostError>) -> Void) {
        do {
            let envelope = try message.seal(with: circleKey)
            // Frame: 4-byte big-endian length prefix + envelope (same as GhostConnection)
            var frame = Data(count: 4)
            let length = UInt32(envelope.count)
            frame[0] = UInt8((length >> 24) & 0xFF)
            frame[1] = UInt8((length >> 16) & 0xFF)
            frame[2] = UInt8((length >> 8) & 0xFF)
            frame[3] = UInt8(length & 0xFF)
            frame.append(envelope)

            try session.send(frame, toPeers: [peerID], with: .reliable)
            completion(.success(()))
        } catch let error as VeuGhostError {
            completion(.failure(error))
        } catch {
            completion(.failure(.connectionFailed(error.localizedDescription)))
        }
    }

    public func receive(completion: @escaping (Result<GhostMessage, VeuGhostError>) -> Void) {
        lock.lock()
        if let data = receiveQueue.first {
            receiveQueue.removeFirst()
            lock.unlock()
            decodeAndComplete(data: data, completion: completion)
        } else {
            pendingReceive = completion
            lock.unlock()
        }
    }

    public func cancel() {
        // MultipeerConnectivity handles disconnect at the session level
    }

    // MARK: - Internal

    /// Called by MeshTransport when data arrives from this peer.
    func enqueueReceived(_ data: Data) {
        lock.lock()
        if let pending = pendingReceive {
            pendingReceive = nil
            lock.unlock()
            decodeAndComplete(data: data, completion: pending)
        } else {
            receiveQueue.append(data)
            lock.unlock()
        }
    }

    private func decodeAndComplete(data: Data, completion: @escaping (Result<GhostMessage, VeuGhostError>) -> Void) {
        // Parse length-prefixed frame
        guard data.count >= 4 else {
            completion(.failure(.decodingFailed("Frame too short")))
            return
        }

        let length = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        let envelope = data.dropFirst(4)

        guard envelope.count == Int(length) else {
            completion(.failure(.decodingFailed("Incomplete frame")))
            return
        }

        do {
            let message = try GhostMessage.open(envelope: Data(envelope), with: circleKey)
            completion(.success(message))
        } catch let error as VeuGhostError {
            completion(.failure(error))
        } catch {
            completion(.failure(.decodingFailed(error.localizedDescription)))
        }
    }
}
