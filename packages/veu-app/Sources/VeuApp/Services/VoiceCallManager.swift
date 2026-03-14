// VoiceCallManager.swift — Veu Protocol: Voice call state machine
//
// Manages the lifecycle of 1:1 calls and circle voice rooms.
// Coordinates between signaling (GhostMessage), audio pipeline
// (AudioEngine + AudioCodec), and encrypted frame transport.

import Foundation
import VeuGhost

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Voice call state.
public enum VoiceCallState: Equatable {
    case idle
    case outgoingRinging(callID: String, recipientDevice: String)
    case incomingRinging(callID: String, callerDevice: String, callerCallsign: String)
    case active(callID: String, peerDevice: String, peerCallsign: String)
    case inRoom(roomID: String, participants: [String])
    case ended(reason: String)
}

/// Manages voice call lifecycle and audio pipeline.
public final class VoiceCallManager: ObservableObject {
    @Published public private(set) var state: VoiceCallState = .idle
    @Published public var isMuted: Bool = false
    @Published public var isSpeakerOn: Bool = false
    @Published public private(set) var callDuration: TimeInterval = 0

    // Dependencies
    public var circleKey: Data?
    public var deviceID: String = ""
    public var callsign: String = ""

    /// Send a voice signal to a peer via the Ghost Network (TCP).
    public var sendSignal: ((GhostMessage.VoiceCallPayload) -> Void)?
    /// Send audio frame via TCP fallback (used when UDP unavailable).
    public var sendAudioFrame: ((Data) -> Void)?

    #if os(iOS)
    private let audioEngine = AudioEngine()
    private let codec = AudioCodec()
    private var udpSocket: VoiceUDPSocket?
    private var peerUDPConnected = false
    #endif
    private var sequenceNumber: UInt16 = 0
    private var ringTimer: Timer?
    private var durationTimer: Timer?
    private var callStartTime: Date?
    private var seenSignals: Set<String> = []
    /// Peer's UDP addresses from signaling (for connecting after accept).
    private var peerAudioAddresses: [String] = []
    private var peerAudioUDPPort: UInt16 = 0

    private static let ringTimeout: TimeInterval = 30

    public init() {}

    // MARK: - Outgoing Call (1:1)

    /// Initiate a 1:1 call to a specific peer.
    public func startCall(to recipientDeviceID: String) -> String {
        let callID = UUID().uuidString

        #if os(iOS)
        setupUDP()
        #endif

        var payload = GhostMessage.VoiceCallPayload(
            callID: callID,
            action: .offer,
            senderDeviceID: deviceID,
            senderCallsign: callsign,
            recipientDeviceID: recipientDeviceID
        )
        #if os(iOS)
        payload.audioUDPPort = udpSocket?.localPort
        payload.audioAddresses = Self.localIPAddresses()
        print("[VoiceCall] 📤 Offer UDP port: \(payload.audioUDPPort ?? 0), addrs: \(payload.audioAddresses ?? [])")
        #endif
        sendSignal?(payload)
        state = .outgoingRinging(callID: callID, recipientDevice: recipientDeviceID)
        startRingTimer(callID: callID)
        return callID
    }

    // MARK: - Incoming Call

    /// Handle an incoming call offer from a peer.
    public func handleIncomingOffer(_ payload: GhostMessage.VoiceCallPayload) {
        guard case .idle = state else {
            print("[VoiceCall] ⚠️ Rejecting offer — busy (state: \(state))")
            rejectCall(callID: payload.callID, recipientDeviceID: payload.senderDeviceID)
            return
        }
        print("[VoiceCall] 📞 Incoming call from \(payload.senderCallsign) (\(payload.senderDeviceID.prefix(8)))")

        // Store peer's UDP info for when we accept
        peerAudioAddresses = payload.audioAddresses ?? []
        peerAudioUDPPort = payload.audioUDPPort ?? 0
        print("[VoiceCall] 📥 Offer UDP port: \(peerAudioUDPPort), addrs: \(peerAudioAddresses)")

        state = .incomingRinging(
            callID: payload.callID,
            callerDevice: payload.senderDeviceID,
            callerCallsign: payload.senderCallsign
        )
        startRingTimer(callID: payload.callID)
    }

    /// Accept the incoming call.
    public func acceptCall() {
        guard case .incomingRinging(let callID, let callerDevice, let callerCallsign) = state else { return }
        cancelRingTimer()

        #if os(iOS)
        setupUDP()
        connectUDPToPeer()
        #endif

        var payload = GhostMessage.VoiceCallPayload(
            callID: callID,
            action: .answer,
            senderDeviceID: deviceID,
            senderCallsign: callsign,
            recipientDeviceID: callerDevice,
            accepted: true
        )
        #if os(iOS)
        payload.audioUDPPort = udpSocket?.localPort
        payload.audioAddresses = Self.localIPAddresses()
        print("[VoiceCall] 📤 Answer UDP port: \(payload.audioUDPPort ?? 0), addrs: \(payload.audioAddresses ?? [])")
        #endif
        sendSignal?(payload)
        transitionToActive(callID: callID, peerDevice: callerDevice, peerCallsign: callerCallsign)
    }

    /// Decline the incoming call.
    public func declineCall() {
        guard case .incomingRinging(let callID, let callerDevice, _) = state else { return }
        rejectCall(callID: callID, recipientDeviceID: callerDevice)
        endCallCleanup(reason: "Declined")
    }

    // MARK: - Call Answer Handling

    /// Handle a call answer from the remote peer.
    public func handleAnswer(_ payload: GhostMessage.VoiceCallPayload) {
        guard case .outgoingRinging(let callID, _) = state else {
            print("[VoiceCall] ⚠️ Ignoring answer — not in outgoingRinging state (current: \(state))")
            return
        }
        guard payload.callID == callID else {
            print("[VoiceCall] ⚠️ Ignoring answer — callID mismatch")
            return
        }
        cancelRingTimer()

        if payload.accepted == true {
            print("[VoiceCall] ✅ Call answered by \(payload.senderCallsign)")
            // Store peer's UDP info and connect
            peerAudioAddresses = payload.audioAddresses ?? []
            peerAudioUDPPort = payload.audioUDPPort ?? 0
            #if os(iOS)
            connectUDPToPeer()
            #endif
            transitionToActive(callID: callID, peerDevice: payload.senderDeviceID, peerCallsign: payload.senderCallsign)
        } else {
            print("[VoiceCall] ❌ Call declined by peer")
            endCallCleanup(reason: "Declined by peer")
        }
    }

    // MARK: - End Call

    /// End the current call.
    public func endCall() {
        let callID: String
        let peerDevice: String?

        switch state {
        case .outgoingRinging(let id, let peer):
            callID = id; peerDevice = peer
        case .incomingRinging(let id, let peer, _):
            callID = id; peerDevice = peer
        case .active(let id, let peer, _):
            callID = id; peerDevice = peer
        case .inRoom(let roomID, _):
            leaveRoom(roomID: roomID)
            return
        default:
            return
        }

        let payload = GhostMessage.VoiceCallPayload(
            callID: callID,
            action: .end,
            senderDeviceID: deviceID,
            senderCallsign: callsign,
            recipientDeviceID: peerDevice,
            reason: "User ended"
        )
        sendSignal?(payload)
        endCallCleanup(reason: "Call ended")
    }

    /// Handle a remote end signal.
    public func handleEnd(_ payload: GhostMessage.VoiceCallPayload) {
        // Only end if the signal matches our active call
        let currentCallID: String?
        switch state {
        case .outgoingRinging(let id, _), .incomingRinging(let id, _, _), .active(let id, _, _):
            currentCallID = id
        default:
            currentCallID = nil
        }
        guard let current = currentCallID, payload.callID == current else {
            print("[VoiceCall] ⚠️ Ignoring end signal — callID mismatch or idle")
            return
        }
        print("[VoiceCall] 📴 Peer ended call: \(payload.reason ?? "no reason")")
        endCallCleanup(reason: payload.reason ?? "Peer ended")
    }

    // MARK: - Voice Rooms (Circle)

    /// Open a voice room for the circle.
    public func openRoom(circleID: String) -> String {
        let roomID = UUID().uuidString
        let payload = GhostMessage.VoiceCallPayload(
            callID: roomID,
            action: .roomOpen,
            senderDeviceID: deviceID,
            senderCallsign: callsign,
            circleID: circleID
        )
        sendSignal?(payload)
        state = .inRoom(roomID: roomID, participants: [callsign])
        startAudioPipeline()
        return roomID
    }

    /// Join an existing voice room.
    public func joinRoom(roomID: String, circleID: String) {
        let payload = GhostMessage.VoiceCallPayload(
            callID: roomID,
            action: .roomJoin,
            senderDeviceID: deviceID,
            senderCallsign: callsign,
            circleID: circleID
        )
        sendSignal?(payload)
        state = .inRoom(roomID: roomID, participants: [callsign])
        startAudioPipeline()
    }

    /// Leave the voice room.
    public func leaveRoom(roomID: String) {
        let payload = GhostMessage.VoiceCallPayload(
            callID: roomID,
            action: .roomLeave,
            senderDeviceID: deviceID,
            senderCallsign: callsign
        )
        sendSignal?(payload)
        endCallCleanup(reason: "Left room")
    }

    /// Handle a peer joining the room.
    public func handleRoomJoin(_ payload: GhostMessage.VoiceCallPayload) {
        guard case .inRoom(let roomID, var participants) = state,
              payload.callID == roomID else { return }
        if !participants.contains(payload.senderCallsign) {
            participants.append(payload.senderCallsign)
            state = .inRoom(roomID: roomID, participants: participants)
        }
    }

    /// Handle a peer leaving the room.
    public func handleRoomLeave(_ payload: GhostMessage.VoiceCallPayload) {
        guard case .inRoom(let roomID, var participants) = state,
              payload.callID == roomID else { return }
        participants.removeAll { $0 == payload.senderCallsign }
        state = .inRoom(roomID: roomID, participants: participants)
    }

    // MARK: - Audio Frame Handling

    /// Handle a received encrypted audio frame.
    public func handleReceivedAudioFrame(_ frameData: Data) {
        #if os(iOS)
        guard frameData.count >= 3 else { return }

        // Parse: [2-byte seq][compressed audio] — skip seq (TCP delivers in order)
        let compressedAudio = frameData.subdata(in: 2..<frameData.count)
        let pcmData = codec.decode(compressedAudio)
        audioEngine.playBuffer(pcmData)
        #endif
    }

    // MARK: - Dispatch incoming voice signals

    /// Route an incoming voice call payload to the appropriate handler.
    public func handleVoiceSignal(_ payload: GhostMessage.VoiceCallPayload) {
        // Ignore our own messages echoed back from relay/broadcast
        guard payload.senderDeviceID != deviceID else {
            if payload.action != .audioFrame {
                print("[VoiceCall] ↩️ Ignoring self-echo: \(payload.action)")
            }
            return
        }

        // Deduplicate signaling messages (relay + LAN can deliver the same signal)
        if payload.action != .audioFrame {
            let key = "\(payload.callID):\(payload.action):\(payload.senderDeviceID)"
            guard !seenSignals.contains(key) else {
                print("[VoiceCall] 🔁 Ignoring duplicate signal: \(payload.action)")
                return
            }
            seenSignals.insert(key)
        }

        // Handle audio frames on background queue for low latency
        if payload.action == .audioFrame {
            if let frameData = payload.audioFrameData {
                handleReceivedAudioFrame(frameData)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch payload.action {
            case .offer:
                self.handleIncomingOffer(payload)
            case .answer:
                self.handleAnswer(payload)
            case .end:
                self.handleEnd(payload)
            case .roomOpen:
                // Another peer opened a room — notify UI (don't auto-join)
                break
            case .roomJoin:
                self.handleRoomJoin(payload)
            case .roomLeave:
                self.handleRoomLeave(payload)
            case .audioFrame:
                break // handled above
            }
        }
    }

    // MARK: - Private

    private func transitionToActive(callID: String, peerDevice: String, peerCallsign: String) {
        state = .active(callID: callID, peerDevice: peerDevice, peerCallsign: peerCallsign)
        startAudioPipeline()
        callStartTime = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let start = self?.callStartTime else { return }
            self?.callDuration = Date().timeIntervalSince(start)
        }
    }

    private func startAudioPipeline() {
        #if os(iOS)
        sequenceNumber = 0
        do {
            try audioEngine.start()
            audioEngine.onCapturedBuffer = { [weak self] pcmData in
                self?.processCapturedAudio(pcmData)
            }
            print("[VoiceCall] 🎙️ Audio pipeline started (UDP: \(peerUDPConnected ? "yes" : "no, TCP fallback"))")
        } catch {
            print("[VoiceCallManager] Failed to start audio: \(error)")
            endCallCleanup(reason: "Audio error")
        }
        #endif
    }

    private func processCapturedAudio(_ pcmData: Data) {
        #if os(iOS)
        let compressed = codec.encode(pcmData)

        // Frame: [2-byte big-endian seq][compressed audio]
        var frame = Data()
        var seq = sequenceNumber.bigEndian
        frame.append(Data(bytes: &seq, count: 2))
        frame.append(compressed)
        sequenceNumber &+= 1

        // Prefer UDP, fall back to TCP
        if peerUDPConnected, let socket = udpSocket {
            socket.sendFrame(frame)
        } else {
            sendAudioFrame?(frame)
        }
        #endif
    }

    private func rejectCall(callID: String, recipientDeviceID: String) {
        let payload = GhostMessage.VoiceCallPayload(
            callID: callID,
            action: .answer,
            senderDeviceID: deviceID,
            senderCallsign: callsign,
            recipientDeviceID: recipientDeviceID,
            accepted: false
        )
        sendSignal?(payload)
    }

    private func endCallCleanup(reason: String) {
        print("[VoiceCall] 🧹 Cleanup: \(reason)")
        cancelRingTimer()
        durationTimer?.invalidate()
        durationTimer = nil
        callStartTime = nil
        callDuration = 0
        sequenceNumber = 0
        seenSignals.removeAll()
        peerAudioAddresses = []
        peerAudioUDPPort = 0
        #if os(iOS)
        audioEngine.stop()
        audioEngine.onCapturedBuffer = nil
        udpSocket?.stop()
        udpSocket = nil
        peerUDPConnected = false
        #endif
        state = .ended(reason: reason)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if case .ended = self?.state {
                self?.state = .idle
            }
        }
    }

    private func startRingTimer(callID: String) {
        cancelRingTimer()
        ringTimer = Timer.scheduledTimer(withTimeInterval: Self.ringTimeout, repeats: false) { [weak self] _ in
            self?.endCallCleanup(reason: "No answer")
        }
    }

    private func cancelRingTimer() {
        ringTimer?.invalidate()
        ringTimer = nil
    }

    // MARK: - UDP Audio Transport

    #if os(iOS)
    private func setupUDP() {
        guard let key = circleKey else { return }
        let socket = VoiceUDPSocket(circleKey: key)
        socket.onFrameReceived = { [weak self] packet in
            guard let self = self, let decrypted = socket.decryptFrame(packet) else { return }
            self.handleReceivedAudioFrame(decrypted)
        }
        do {
            try socket.startListening()
            self.udpSocket = socket
        } catch {
            print("[VoiceCall] ⚠️ UDP listen failed: \(error), will use TCP fallback")
        }
    }

    private func connectUDPToPeer() {
        guard peerAudioUDPPort > 0, !peerAudioAddresses.isEmpty else {
            print("[VoiceCall] No peer UDP info — using TCP fallback")
            return
        }
        // Try first available address (prefer non-link-local IPv4)
        let preferred = peerAudioAddresses.first { !$0.hasPrefix("fe80") } ?? peerAudioAddresses.first
        guard let host = preferred else { return }

        udpSocket?.connectToPeer(host: host, port: peerAudioUDPPort)
        peerUDPConnected = true
        print("[VoiceCall] 🔗 UDP connected to \(host):\(peerAudioUDPPort)")
    }
    #endif

    /// Get this device's local IP addresses for UDP audio.
    static func localIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addresses }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            let sa = ifa.pointee.ifa_addr.pointee
            if sa.sa_family == UInt8(AF_INET) || sa.sa_family == UInt8(AF_INET6) {
                let name = String(cString: ifa.pointee.ifa_name)
                // Only include WiFi (en0) and cellular (pdp_ip) interfaces
                if name == "en0" || name.hasPrefix("pdp_ip") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ifa.pointee.ifa_addr, socklen_t(sa.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let addr = String(cString: hostname)
                        addresses.append(addr)
                    }
                }
            }
            ptr = ifa.pointee.ifa_next
        }
        return addresses
    }
}
