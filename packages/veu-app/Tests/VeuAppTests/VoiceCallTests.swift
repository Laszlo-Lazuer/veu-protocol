import Testing
import Foundation
@testable import VeuApp
import VeuGhost

// MARK: - JitterBuffer Tests

@Suite("JitterBuffer")
struct JitterBufferTests {

    @Test("In-order frames are pulled sequentially")
    func inOrderPull() {
        let jb = JitterBuffer(maxDelay: 5)
        jb.insert(sequence: 0, data: Data([0x00]))
        jb.insert(sequence: 1, data: Data([0x01]))
        jb.insert(sequence: 2, data: Data([0x02]))

        #expect(jb.pull() == Data([0x00]))
        #expect(jb.pull() == Data([0x01]))
        #expect(jb.pull() == Data([0x02]))
        #expect(jb.pull() == nil)
    }

    @Test("Out-of-order frames are reordered")
    func outOfOrderReorder() {
        let jb = JitterBuffer(maxDelay: 5)
        jb.insert(sequence: 2, data: Data([0x02]))
        jb.insert(sequence: 0, data: Data([0x00]))
        jb.insert(sequence: 1, data: Data([0x01]))

        #expect(jb.pull() == Data([0x00]))
        #expect(jb.pull() == Data([0x01]))
        #expect(jb.pull() == Data([0x02]))
    }

    @Test("Gap in sequence is skipped when buffer full")
    func gapSkipping() {
        let jb = JitterBuffer(maxDelay: 3)
        // Insert frames 0, 2, 3, 4 — skip frame 1
        jb.insert(sequence: 0, data: Data([0x00]))
        #expect(jb.pull() == Data([0x00])) // seq 0

        jb.insert(sequence: 2, data: Data([0x02]))
        jb.insert(sequence: 3, data: Data([0x03]))
        jb.insert(sequence: 4, data: Data([0x04]))

        // Buffer is full (3 frames), should skip gap and emit seq 2
        let frame = jb.pull()
        #expect(frame == Data([0x02]))
    }

    @Test("Reset clears all state")
    func resetClears() {
        let jb = JitterBuffer(maxDelay: 5)
        jb.insert(sequence: 0, data: Data([0x00]))
        jb.insert(sequence: 1, data: Data([0x01]))

        jb.reset()

        #expect(jb.pull() == nil)

        // After reset, can start fresh from seq 0
        jb.insert(sequence: 0, data: Data([0xAA]))
        #expect(jb.pull() == Data([0xAA]))
    }

    @Test("Sequence number wrapping (UInt16 overflow)")
    func sequenceWrapping() {
        let jb = JitterBuffer(maxDelay: 5)
        jb.insert(sequence: UInt16.max - 1, data: Data([0xFE]))
        jb.insert(sequence: UInt16.max, data: Data([0xFF]))

        // Pull first two
        _ = jb.pull()
        _ = jb.pull()

        // Now insert wrapped sequence
        jb.insert(sequence: 0, data: Data([0x00]))
        jb.insert(sequence: 1, data: Data([0x01]))

        // Should pull these (may skip due to wrap detection)
        let f1 = jb.pull()
        #expect(f1 != nil)
    }
}

// MARK: - VoiceCallManager State Machine Tests

@Suite("VoiceCallManager State Machine")
struct VoiceCallManagerStateTests {

    private func makeManager() -> VoiceCallManager {
        let mgr = VoiceCallManager()
        mgr.deviceID = "test_device_001"
        mgr.callsign = "TEST01"
        mgr.circleID = "circle_001"
        mgr.circleKey = Data(repeating: 0xAB, count: 32)
        // Swallow signals in tests
        mgr.sendSignal = { _ in }
        mgr.sendAudioFrame = { _ in }
        return mgr
    }

    @Test("Initial state is idle")
    func initialIdle() {
        let mgr = makeManager()
        #expect(mgr.state == .idle)
    }

    @Test("Start call transitions to outgoingRinging")
    func startCallTransition() {
        let mgr = makeManager()
        let callID = mgr.startCall(to: "peer_device_002")

        if case .outgoingRinging(let id, let peer) = mgr.state {
            #expect(id == callID)
            #expect(peer == "peer_device_002")
        } else {
            Issue.record("Expected outgoingRinging, got \(mgr.state)")
        }
    }

    @Test("Incoming offer transitions to incomingRinging")
    func incomingOfferTransition() {
        let mgr = makeManager()
        let payload = GhostMessage.VoiceCallPayload(
            callID: "call_123",
            action: .offer,
            senderDeviceID: "peer_device_003",
            senderCallsign: "PEER03",
            recipientDeviceID: "test_device_001"
        )
        mgr.handleIncomingOffer(payload)

        if case .incomingRinging(let id, let device, let callsign) = mgr.state {
            #expect(id == "call_123")
            #expect(device == "peer_device_003")
            #expect(callsign == "PEER03")
        } else {
            Issue.record("Expected incomingRinging, got \(mgr.state)")
        }
    }

    @Test("Reject offer when busy")
    func rejectWhenBusy() {
        let mgr = makeManager()
        _ = mgr.startCall(to: "peer_a")

        var rejectedCallID: String?
        mgr.sendSignal = { payload in
            if payload.action == .answer && payload.accepted == false {
                rejectedCallID = payload.callID
            }
        }

        let busyPayload = GhostMessage.VoiceCallPayload(
            callID: "call_busy",
            action: .offer,
            senderDeviceID: "peer_b",
            senderCallsign: "PEERB",
            recipientDeviceID: "test_device_001"
        )
        mgr.handleIncomingOffer(busyPayload)
        #expect(rejectedCallID == "call_busy")
    }

    @Test("End call transitions to ended then idle")
    func endCallTransition() {
        let mgr = makeManager()
        _ = mgr.startCall(to: "peer_device_002")
        mgr.endCall()

        if case .ended(let reason) = mgr.state {
            #expect(reason == "Call ended")
        } else {
            Issue.record("Expected ended, got \(mgr.state)")
        }
    }

    @Test("Decline incoming call")
    func declineIncoming() {
        let mgr = makeManager()
        let payload = GhostMessage.VoiceCallPayload(
            callID: "call_decline",
            action: .offer,
            senderDeviceID: "peer_d",
            senderCallsign: "PEERD",
            recipientDeviceID: "test_device_001"
        )
        mgr.handleIncomingOffer(payload)
        mgr.declineCall()

        if case .ended(let reason) = mgr.state {
            #expect(reason == "Declined")
        } else {
            Issue.record("Expected ended, got \(mgr.state)")
        }
    }

    @Test("Call end signal from peer ends call")
    func peerEndSignal() {
        let mgr = makeManager()
        _ = mgr.startCall(to: "peer_e")

        guard case .outgoingRinging(let callID, _) = mgr.state else {
            Issue.record("Not ringing")
            return
        }

        let endPayload = GhostMessage.VoiceCallPayload(
            callID: callID,
            action: .end,
            senderDeviceID: "peer_e",
            senderCallsign: "PEERE",
            reason: "User ended"
        )
        mgr.handleEnd(endPayload)

        if case .ended(let reason) = mgr.state {
            #expect(reason == "User ended")
        } else {
            Issue.record("Expected ended, got \(mgr.state)")
        }
    }

    @Test("Ignores end signal with wrong callID")
    func ignoreWrongCallIDEnd() {
        let mgr = makeManager()
        _ = mgr.startCall(to: "peer_f")

        let wrongEnd = GhostMessage.VoiceCallPayload(
            callID: "wrong_call_id",
            action: .end,
            senderDeviceID: "peer_f",
            senderCallsign: "PEERF"
        )
        mgr.handleEnd(wrongEnd)

        // State should remain outgoingRinging (not ended)
        if case .outgoingRinging = mgr.state {
            // Good
        } else {
            Issue.record("State changed unexpectedly: \(mgr.state)")
        }
    }

    @Test("Self-echo signals are ignored")
    func selfEchoIgnored() {
        let mgr = makeManager()

        let echoPayload = GhostMessage.VoiceCallPayload(
            callID: "call_echo",
            action: .offer,
            senderDeviceID: "test_device_001", // Same as our device
            senderCallsign: "TEST01"
        )
        mgr.handleVoiceSignal(echoPayload)

        // Should remain idle — echo was ignored
        #expect(mgr.state == .idle)
    }

    @Test("Duplicate signals are deduplicated")
    func duplicateDedup() {
        let mgr = makeManager()

        let payload = GhostMessage.VoiceCallPayload(
            callID: "call_dup",
            action: .offer,
            senderDeviceID: "peer_dup",
            senderCallsign: "DUP",
            recipientDeviceID: "test_device_001"
        )

        // First: handle directly (synchronous) to set state
        mgr.handleIncomingOffer(payload)
        #expect(mgr.state == .incomingRinging(
            callID: "call_dup",
            callerDevice: "peer_dup",
            callerCallsign: "DUP"
        ))

        // Second: via handleVoiceSignal — dedup key should reject it.
        // Since we're already in incomingRinging, a second offer from same peer
        // would be rejected as busy if it got through. The dedup prevents that.
        mgr.handleVoiceSignal(payload)
        // If dedup failed, handleIncomingOffer would be called again and reject
        // (busy), which would change state. State should remain incomingRinging.
        #expect(mgr.state == .incomingRinging(
            callID: "call_dup",
            callerDevice: "peer_dup",
            callerCallsign: "DUP"
        ))
    }
}

// MARK: - Voice Room Tests

@Suite("VoiceCallManager Rooms")
struct VoiceRoomTests {

    private func makeManager() -> VoiceCallManager {
        let mgr = VoiceCallManager()
        mgr.deviceID = "room_device"
        mgr.callsign = "ROOM01"
        mgr.sendSignal = { _ in }
        mgr.sendAudioFrame = { _ in }
        return mgr
    }

    @Test("Open room transitions to inRoom")
    func openRoom() {
        let mgr = makeManager()
        let roomID = mgr.openRoom(circleID: "circle_1")

        if case .inRoom(let id, let participants) = mgr.state {
            #expect(id == roomID)
            #expect(participants == ["ROOM01"])
        } else {
            Issue.record("Expected inRoom")
        }
    }

    @Test("Join room transitions to inRoom")
    func joinRoom() {
        let mgr = makeManager()
        mgr.joinRoom(roomID: "room_abc", circleID: "circle_1")

        if case .inRoom(let id, _) = mgr.state {
            #expect(id == "room_abc")
        } else {
            Issue.record("Expected inRoom")
        }
    }

    @Test("Room peer join adds participant")
    func roomPeerJoin() {
        let mgr = makeManager()
        _ = mgr.openRoom(circleID: "circle_1")

        let joinPayload = GhostMessage.VoiceCallPayload(
            callID: mgr.state == .idle ? "" : {
                if case .inRoom(let id, _) = mgr.state { return id }
                return ""
            }(),
            action: .roomJoin,
            senderDeviceID: "peer_room",
            senderCallsign: "JOINR"
        )
        mgr.handleRoomJoin(joinPayload)

        if case .inRoom(_, let participants) = mgr.state {
            #expect(participants.contains("JOINR"))
        }
    }

    @Test("Leave room transitions to ended")
    func leaveRoom() {
        let mgr = makeManager()
        let roomID = mgr.openRoom(circleID: "circle_1")
        mgr.leaveRoom(roomID: roomID)

        if case .ended(let reason) = mgr.state {
            #expect(reason == "Left room")
        } else {
            Issue.record("Expected ended")
        }
    }
}
