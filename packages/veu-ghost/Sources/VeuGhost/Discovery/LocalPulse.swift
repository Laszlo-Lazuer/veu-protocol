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
public final class LocalPulse: DiscoveryService {

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

    /// The device name used for the advertised service (to filter self-discovery).
    public var serviceName: String?
    
    /// Pre-computed expected service name prefix (for self-filtering before registration completes).
    private var expectedServiceNamePrefix: String?

    /// Discovery delegate (protocol-conformance bridge).
    public weak var discoveryDelegate: (any DiscoveryDelegate)?

    /// Start advertising and discovering peers (DiscoveryService conformance).
    public func startDiscovery() throws {
        try start()
    }

    /// Stop advertising and discovering (DiscoveryService conformance).
    public func stopDiscovery() {
        stop()
    }

    /// Create a LocalPulse for a given Circle.
    ///
    /// - Parameters:
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - deviceName: Human-readable device name (callsign).
    ///   - queue: Dispatch queue for events (default: `.main`).
    public init(circleKey: Data, deviceName: String = "Veu", queue: DispatchQueue = .main) {
        self.circleKey = circleKey
        self.topicHash = GhostConnection.circleTopicHash(circleKey: circleKey)
        self.deviceName = deviceName
        self.queue = queue
    }
    
    /// The device name for service advertisement.
    private let deviceName: String

    // MARK: - Start / Stop

    /// Start advertising and browsing for peers.
    ///
    /// - Parameter port: The TCP port to listen on (default: any available).
    /// - Throws: `VeuGhostError.discoveryFailed` if the listener cannot be created.
    public func start(port: NWEndpoint.Port = .any) throws {
        guard !isActive else { return }

        // --- Listener (advertise) ---
        // includePeerToPeer = true enables AWDL (Wi-Fi Direct) so phones can
        // sync without a shared router. The OS prefers same-network Wi-Fi
        // automatically; AWDL is used as a fallback.
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            throw VeuGhostError.discoveryFailed("Failed to create listener: \(error.localizedDescription)")
        }

        // Embed topic hash prefix in service name for reliable filtering
        // Format: "DeviceName~TopicPrefix" (e.g., "Squirrel~de23f5f8")
        let topicPrefix = String(topicHash.prefix(8))
        let advertisedName = "\(deviceName)~\(topicPrefix)"
        
        // Pre-compute the expected service name prefix for self-filtering
        // The OS may append " (2)", " (3)", etc. for duplicate names
        self.expectedServiceNamePrefix = advertisedName
        
        let txtRecord = NWTXTRecord(["topic": topicHash])
        listener.service = NWListener.Service(name: advertisedName, type: Self.serviceType, txtRecord: txtRecord)
        // Capture advertised name after listener starts for self-filtering
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if case .add(let endpoint) = change,
               case .service(let name, _, _, _) = endpoint {
                self?.serviceName = name
                print("[LocalPulse] Registered as: \(name)")
            }
        }

        listener.stateUpdateHandler = { [weak self] state in
            print("[LocalPulse] Listener state: \(state)")
            if case .failed(let error) = state {
                print("[LocalPulse] Listener failed: \(error)")
                self?.stop()
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            print("[LocalPulse] New inbound connection from \(connection.endpoint)")
            connection.start(queue: self.queue)
            self.delegate?.localPulse(self, didAcceptConnection: connection)
        }

        listener.start(queue: queue)
        self.listener = listener

        // --- Browser (discover) ---
        // Same includePeerToPeer flag so we discover peers on both LAN and AWDL.
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browserParams = NWParameters.tcp
        browserParams.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: browserParams)
        let ourTopicPrefix = String(self.topicHash.prefix(8))

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            print("[LocalPulse] Browse results changed: \(changes.count) changes, \(results.count) total results")
            for change in changes {
                switch change {
                case .added(let result), .changed(old: _, new: let result, flags: _):
                    // Extract service name and check topic prefix
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    
                    // Skip our own service (check both registered name and expected prefix)
                    if name == self.serviceName || self.isSelfService(name) {
                        print("[LocalPulse] Skipping self: \(name)")
                        continue
                    }
                    
                    // Check topic prefix in service name (format: "DeviceName~TopicPrefix")
                    let peerTopicPrefix = self.extractTopicPrefix(from: name)
                    let changeType = { () -> String in
                        if case .added = change { return "added" }
                        return "changed"
                    }()
                    print("[LocalPulse] Peer \(changeType): \(name), topicPrefix=\(peerTopicPrefix ?? "nil"), ours=\(ourTopicPrefix)")
                    
                    if let peerTopicPrefix = peerTopicPrefix, peerTopicPrefix == ourTopicPrefix {
                        print("[LocalPulse] ✅ Topic match — connecting to \(result.endpoint)")
                        self.delegate?.localPulse(self, didDiscover: result.endpoint, topicHash: self.topicHash)
                    } else if let peerTopicPrefix = peerTopicPrefix, peerTopicPrefix != ourTopicPrefix {
                        print("[LocalPulse] ❌ Topic mismatch — ignoring \(name)")
                    } else {
                        // Old-style service name without topic prefix — skip
                        print("[LocalPulse] ⏳ No topic in name — ignoring legacy service \(name)")
                    }
                case .removed(let result):
                    print("[LocalPulse] Peer removed: \(result.endpoint)")
                    self.delegate?.localPulse(self, didLose: result.endpoint)
                default:
                    break
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            print("[LocalPulse] Browser state: \(state)")
            if case .failed(let error) = state {
                print("[LocalPulse] Browser failed: \(error)")
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

    /// Extract topic prefix from service name (format: "DeviceName~TopicPrefix")
    /// Handles OS-appended duplicate suffixes like " (2)", " (3)", etc.
    private func extractTopicPrefix(from serviceName: String) -> String? {
        let parts = serviceName.split(separator: "~")
        guard parts.count == 2 else { return nil }
        let raw = String(parts[1])
        // Strip OS duplicate suffix: "69b0a8d2 (2)" → "69b0a8d2"
        if let spaceIdx = raw.firstIndex(of: " ") {
            return String(raw[raw.startIndex..<spaceIdx])
        }
        return raw
    }
    
    /// Check if a service name represents our own service (handles OS suffixes like " (2)")
    private func isSelfService(_ name: String) -> Bool {
        guard let prefix = expectedServiceNamePrefix else { return false }
        // Exact match or starts with our expected name followed by OS suffix
        return name == prefix || name.hasPrefix(prefix + " (")
    }
    
    private func extractTopicHash(from result: NWBrowser.Result) -> String? {
        if case .bonjour(let record) = result.metadata {
            return record["topic"]
        }
        return nil
    }
}
