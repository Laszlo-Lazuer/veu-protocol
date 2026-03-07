// LocalPulse.swift — Veu Protocol: mDNS/Bonjour Peer Discovery
//
// Broadcasts and discovers Ghost Network peers on the local Wi-Fi using
// Apple's Network framework (NWBrowser + NWListener).  The service TXT
// record contains an HMAC-derived Circle topic hash so that only members
// of the same Circle can recognize each other.

import Foundation
import Network

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Delegate for LocalPulse peer discovery events.
public protocol LocalPulseDelegate: AnyObject {
    /// A new peer was discovered on the local network.
    func localPulse(_ pulse: LocalPulse, didDiscover endpoint: NWEndpoint, topicHash: String)

    /// A previously discovered peer is no longer available.
    func localPulse(_ pulse: LocalPulse, didLose endpoint: NWEndpoint)

    /// An inbound peer connection was received.
    func localPulse(_ pulse: LocalPulse, didAcceptConnection connection: NWConnection)
}

/// mDNS/Bonjour service for Ghost Network peer discovery.
///
/// Advertises a `_veu-ghost._tcp` service with a TXT record containing
/// the Circle topic hash.  Simultaneously browses for peers advertising
/// the same service.  Only peers sharing a Circle Key can match the
/// topic hash and initiate a sync.
public final class LocalPulse {

    /// The Bonjour service type used for Ghost Network discovery.
    public static let serviceType = "_veu-ghost._tcp"

    /// The Circle Key this pulse is advertising for.
    public let circleKey: Data

    /// The hex-encoded Circle topic hash (in TXT record).
    public let topicHash: String

    /// Delegate receiving discovery events.
    public weak var delegate: LocalPulseDelegate?

    /// The dispatch queue for network events.
    private let queue: DispatchQueue

    /// The NWListener (advertiser).
    private var listener: NWListener?

    /// The NWBrowser (discoverer).
    private var browser: NWBrowser?

    /// Whether the pulse is currently active.
    public private(set) var isActive: Bool = false

    /// Create a LocalPulse for a given Circle.
    ///
    /// - Parameters:
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - queue: Dispatch queue for events (default: `.main`).
    public init(circleKey: Data, queue: DispatchQueue = .main) {
        self.circleKey = circleKey
        self.topicHash = GhostConnection.circleTopicHash(circleKey: circleKey)
        self.queue = queue
    }

    // MARK: - Start / Stop

    /// Start advertising and browsing for peers.
    ///
    /// - Parameter port: The TCP port to listen on (default: any available).
    /// - Throws: `VeuGhostError.discoveryFailed` if the listener cannot be created.
    public func start(port: NWEndpoint.Port = .any) throws {
        guard !isActive else { return }

        // --- Listener (advertise) ---
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            throw VeuGhostError.discoveryFailed("Failed to create listener: \(error.localizedDescription)")
        }

        let txtRecord = NWTXTRecord(["topic": topicHash])
        listener.service = NWListener.Service(type: Self.serviceType, txtRecord: txtRecord)

        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.stop()
                _ = error // Logged in production; no-op in POC
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: self.queue)
            self.delegate?.localPulse(self, didAcceptConnection: connection)
        }

        listener.start(queue: queue)
        self.listener = listener

        // --- Browser (discover) ---
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            for change in changes {
                switch change {
                case .added(let result):
                    if let peerTopic = self.extractTopicHash(from: result),
                       peerTopic == self.topicHash {
                        self.delegate?.localPulse(self, didDiscover: result.endpoint, topicHash: peerTopic)
                    }
                case .removed(let result):
                    self.delegate?.localPulse(self, didLose: result.endpoint)
                default:
                    break
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state {
                self?.stop()
            }
        }

        browser.start(queue: queue)
        self.browser = browser
        self.isActive = true
    }

    /// Stop advertising and browsing.
    public func stop() {
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        isActive = false
    }

    // MARK: - Private

    private func extractTopicHash(from result: NWBrowser.Result) -> String? {
        if case .bonjour(let record) = result.metadata {
            return record["topic"]
        }
        return nil
    }
}
