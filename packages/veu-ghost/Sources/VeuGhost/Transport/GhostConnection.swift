// GhostConnection.swift — Veu Protocol: Encrypted Peer Connection
//
// Wraps an NWConnection with length-prefixed framing and AES-256-GCM
// envelope encryption.  Each message is sent as:
//   [4-byte big-endian length] [encrypted envelope payload]

import Foundation
import Network

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// An encrypted peer-to-peer connection for Ghost Network message exchange.
///
/// Messages are framed as `[uint32 length][AES-256-GCM envelope]` over a
/// raw TCP `NWConnection`.  The Circle Key is used for all encryption.
public final class GhostConnection: @unchecked Sendable {

    /// The underlying Network framework connection.
    public let connection: NWConnection

    /// The Circle Key used for AES-256-GCM encryption of all messages.
    public let circleKey: Data

    /// The remote peer's endpoint description (for logging/debugging).
    public var endpointDescription: String {
        "\(connection.endpoint)"
    }

    /// Connection state changes are forwarded to this handler.
    public var stateHandler: ((NWConnection.State) -> Void)?

    /// Create a GhostConnection wrapping an existing NWConnection.
    ///
    /// - Parameters:
    ///   - connection: An `NWConnection` (inbound from listener or outbound).
    ///   - circleKey: 32-byte Circle symmetric key.
    public init(connection: NWConnection, circleKey: Data) {
        self.connection = connection
        self.circleKey = circleKey
    }

    /// Create an outbound GhostConnection to a discovered peer.
    ///
    /// - Parameters:
    ///   - endpoint: The NWEndpoint (typically from NWBrowser result).
    ///   - circleKey: 32-byte Circle symmetric key.
    public convenience init(endpoint: NWEndpoint, circleKey: Data) {
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)
        self.init(connection: conn, circleKey: circleKey)
    }

    // MARK: - Lifecycle

    /// Start the connection on the given dispatch queue.
    ///
    /// - Parameter queue: The queue for connection events (default: `.global()`).
    public func start(queue: DispatchQueue = .global(qos: .userInitiated)) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateHandler?(state)
        }
        connection.start(queue: queue)
    }

    /// Cancel the connection.
    public func cancel() {
        connection.cancel()
    }

    // MARK: - Send

    /// Encrypt and send a GhostMessage over the connection.
    ///
    /// - Parameters:
    ///   - message: The message to send.
    ///   - completion: Called when the send completes (or fails).
    public func send(_ message: GhostMessage, completion: @escaping (Result<Void, VeuGhostError>) -> Void) {
        let envelope: Data
        do {
            envelope = try message.seal(with: circleKey)
        } catch {
            completion(.failure(error as? VeuGhostError ?? .encryptionFailed(error.localizedDescription)))
            return
        }

        // Frame: 4-byte big-endian length prefix + envelope
        var frame = Data(count: 4)
        let length = UInt32(envelope.count)
        frame[0] = UInt8((length >> 24) & 0xFF)
        frame[1] = UInt8((length >> 16) & 0xFF)
        frame[2] = UInt8((length >> 8) & 0xFF)
        frame[3] = UInt8(length & 0xFF)
        frame.append(envelope)

        connection.send(content: frame, completion: .contentProcessed { error in
            if let error = error {
                completion(.failure(.connectionFailed(error.localizedDescription)))
            } else {
                completion(.success(()))
            }
        })
    }

    // MARK: - Receive

    /// Receive and decrypt a single GhostMessage from the connection.
    ///
    /// Reads the 4-byte length prefix, then the full envelope, then decrypts.
    ///
    /// - Parameter completion: Called with the decoded message or an error.
    public func receive(completion: @escaping (Result<GhostMessage, VeuGhostError>) -> Void) {
        // Read the 4-byte length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(.connectionFailed(error.localizedDescription)))
                return
            }

            guard let lengthData = data, lengthData.count == 4 else {
                completion(.failure(.decodingFailed("Missing or incomplete length prefix")))
                return
            }

            let length = UInt32(lengthData[0]) << 24
                       | UInt32(lengthData[1]) << 16
                       | UInt32(lengthData[2]) << 8
                       | UInt32(lengthData[3])

            guard length > 0, length < 10_000_000 else {
                completion(.failure(.decodingFailed("Invalid frame length: \(length)")))
                return
            }

            // Read the envelope payload
            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, error in
                if let error = error {
                    completion(.failure(.connectionFailed(error.localizedDescription)))
                    return
                }

                guard let envelope = data, envelope.count == Int(length) else {
                    completion(.failure(.decodingFailed("Incomplete envelope payload")))
                    return
                }

                do {
                    let message = try GhostMessage.open(envelope: envelope, with: self.circleKey)
                    completion(.success(message))
                } catch let error as VeuGhostError {
                    completion(.failure(error))
                } catch {
                    completion(.failure(.decodingFailed(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - Static Helpers

    /// Compute a Circle topic hash for mDNS TXT records.
    ///
    /// `HMAC-SHA-256(circleKey, "ghost-pulse-v1")` → hex string.
    /// Only Circle members can compute this hash, so it acts as an
    /// anonymous rendezvous token.
    ///
    /// - Parameter circleKey: The Circle's symmetric key.
    /// - Returns: Hex-encoded topic hash.
    public static func circleTopicHash(circleKey: Data) -> String {
        let key = SymmetricKey(data: circleKey)
        let tag = HMAC<SHA256>.authenticationCode(for: Data("ghost-pulse-v1".utf8), using: key)
        return Data(tag).map { String(format: "%02x", $0) }.joined()
    }
}
