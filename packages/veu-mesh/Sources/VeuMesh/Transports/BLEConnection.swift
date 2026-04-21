// BLEConnection.swift — Veu Protocol: Core Bluetooth Per-Peer Transport Connection
//
// Wraps a single BLE peer into a TransportConnection for use by the sync layer.
// Messages are encrypted with AES-256-GCM (Circle Key) before sending, same as
// all other transports.  Uses BLEChunker for MTU-safe framing.

#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import VeuGhost

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A transport connection over Core Bluetooth (BLE GATT characteristics).
///
/// Conforms to `TransportConnection` so the `SyncEngine` can send/receive
/// `GhostMessage`s over BLE without knowing the underlying transport.
///
/// Each BLEConnection represents a single peer.  It can be either:
/// - **Central-side**: We discovered a peripheral and write to its characteristics
/// - **Peripheral-side**: A central connected to us and writes to our characteristics
public final class BLEConnection: TransportConnection, @unchecked Sendable {

    // MARK: - TransportConnection

    public var endpointDescription: String {
        peerDeviceID
    }

    public var transportName: String = "BLE"

    // MARK: - Properties

    /// The peer's Veu device ID (read from identity characteristic).
    let peerDeviceID: String

    /// The circle key for sealing/opening GhostMessages.
    private let circleKey: Data

    /// Chunker for outbound messages.
    private let sendChunker: BLEChunker

    /// Chunker for inbound reassembly.
    private var receiveChunker: BLEChunker

    /// Abstracted write function — provided by BLETransport depending on
    /// whether this is a central-side or peripheral-side connection.
    private let writeChunks: ([Data]) -> Void

    /// Queue of received frames waiting for `receive()` calls.
    private var receiveQueue: [Data] = []
    private var pendingReceive: ((Result<GhostMessage, VeuGhostError>) -> Void)?
    private let lock = NSLock()

    // MARK: - Init

    /// Create a BLE connection to a peer.
    ///
    /// - Parameters:
    ///   - peerDeviceID: The peer's Veu device ID.
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - mtu: Negotiated BLE MTU for this connection.
    ///   - writeChunks: Closure that writes an array of chunk Data values to the peer.
    init(peerDeviceID: String, circleKey: Data, mtu: Int, writeChunks: @escaping ([Data]) -> Void) {
        self.peerDeviceID = peerDeviceID
        self.circleKey = circleKey
        self.sendChunker = BLEChunker(mtu: mtu)
        self.receiveChunker = BLEChunker(mtu: mtu)
        self.writeChunks = writeChunks
    }

    // MARK: - TransportConnection

    public func send(_ message: GhostMessage, completion: @escaping (Result<Void, VeuGhostError>) -> Void) {
        do {
            let envelope = try message.seal(with: circleKey)

            // Length-prefix (same framing as all other transports)
            var frame = Data(capacity: 4 + envelope.count)
            let length = UInt32(envelope.count)
            frame.append(UInt8((length >> 24) & 0xFF))
            frame.append(UInt8((length >> 16) & 0xFF))
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
            frame.append(envelope)

            // Chunk and write
            let chunks = sendChunker.chunk(frame)
            writeChunks(chunks)
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
        lock.lock()
        pendingReceive = nil
        receiveQueue.removeAll()
        lock.unlock()
    }

    // MARK: - Chunk Ingestion (called by BLETransport)

    /// Feed a raw chunk from a BLE characteristic notification/write.
    /// When a complete frame is reassembled, it's delivered to any pending
    /// `receive()` call or queued for the next one.
    func feedChunk(_ chunk: Data) {
        guard let frame = receiveChunker.feed(chunk) else { return }
        enqueueFrame(frame)
    }

    // MARK: - Internal

    private func enqueueFrame(_ frame: Data) {
        lock.lock()
        if let pending = pendingReceive {
            pendingReceive = nil
            lock.unlock()
            decodeAndComplete(data: frame, completion: pending)
        } else {
            receiveQueue.append(frame)
            lock.unlock()
        }
    }

    private func decodeAndComplete(data: Data, completion: @escaping (Result<GhostMessage, VeuGhostError>) -> Void) {
        // Parse length-prefixed frame
        guard data.count >= 4 else {
            completion(.failure(.decodingFailed("BLE frame too short")))
            return
        }

        let length = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        let envelope = data.dropFirst(4)

        guard envelope.count == Int(length) else {
            completion(.failure(.decodingFailed("BLE frame incomplete: expected \(length), got \(envelope.count)")))
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
#endif
