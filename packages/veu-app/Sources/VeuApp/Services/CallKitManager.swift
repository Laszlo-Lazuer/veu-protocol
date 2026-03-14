// CallKitManager.swift — Veu Protocol: Native iOS call UI via CallKit
//
// Provides native incoming call notifications (lock screen), outgoing call
// UI integration, and audio session management tied to CallKit lifecycle.
// Only used for 1:1 calls — circle voice rooms bypass CallKit.

#if os(iOS)
import CallKit
import AVFoundation

/// Bridges VoiceCallManager to the native iOS call UI.
public final class CallKitManager: NSObject, ObservableObject {

    private let provider: CXProvider
    private let callController = CXCallController()

    /// Called when user answers incoming call via CallKit UI.
    public var onAnswerCall: ((String) -> Void)?
    /// Called when CallKit ends a call — passes the callID string (not UUID).
    public var onEndCall: ((String) -> Void)?
    /// Called when audio session should be configured.
    public var onAudioSessionActivated: (() -> Void)?
    /// Called when audio session is deactivated.
    public var onAudioSessionDeactivated: (() -> Void)?

    /// Map of callID strings to CallKit UUIDs.
    private var callUUIDs: [String: UUID] = [:]

    public override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false  // Privacy: don't leak call history
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    deinit {
        provider.invalidate()
    }

    // MARK: - Report Incoming Call

    /// Report an incoming call to the system (shows native call UI).
    public func reportIncomingCall(callID: String, callerName: String, completion: ((Error?) -> Void)? = nil) {
        let uuid = uuidFor(callID: callID)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error = error {
                print("[CallKit] Failed to report incoming call: \(error)")
                self?.callUUIDs.removeValue(forKey: callID)
            }
            completion?(error)
        }
    }

    // MARK: - Outgoing Call

    /// Start an outgoing call via CallKit.
    public func startOutgoingCall(callID: String, recipientName: String, completion: ((Error?) -> Void)? = nil) {
        let uuid = uuidFor(callID: callID)
        let handle = CXHandle(type: .generic, value: recipientName)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = false

        callController.request(CXTransaction(action: startAction)) { [weak self] error in
            if let error = error {
                print("[CallKit] Failed to start outgoing call: \(error)")
                self?.callUUIDs.removeValue(forKey: callID)
            }
            completion?(error)
        }
    }

    /// Report that an outgoing call has connected.
    public func reportOutgoingCallConnected(callID: String) {
        guard let uuid = callUUIDs[callID] else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    // MARK: - End Call

    /// End a call via CallKit.
    public func endCall(callID: String) {
        guard let uuid = callUUIDs[callID] else { return }
        let endAction = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: endAction)) { error in
            if let error = error {
                print("[CallKit] Failed to end call: \(error)")
            }
        }
    }

    // MARK: - Answer Call from In-App UI

    /// Answer a call via CallKit (use when user taps Accept in our UI).
    public func answerCall(callID: String) {
        guard let uuid = callUUIDs[callID] else { return }
        let answerAction = CXAnswerCallAction(call: uuid)
        callController.request(CXTransaction(action: answerAction)) { error in
            if let error = error {
                print("[CallKit] Failed to answer call: \(error)")
            }
        }
    }

    /// Report that a call ended (remote hangup or error).
    public func reportCallEnded(callID: String, reason: CXCallEndedReason) {
        guard let uuid = callUUIDs[callID] else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        callUUIDs.removeValue(forKey: callID)
    }

    /// Force-clear all tracked calls (use on cleanup to prevent stale state).
    public func clearAllCalls() {
        for (callID, uuid) in callUUIDs {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        callUUIDs.removeAll()
    }

    /// Look up callID for a given UUID.
    public func callID(for uuid: UUID) -> String? {
        callUUIDs.first(where: { $0.value == uuid })?.key
    }

    // MARK: - Private

    private func uuidFor(callID: String) -> UUID {
        if let existing = callUUIDs[callID] { return existing }
        let uuid = UUID()
        callUUIDs[callID] = uuid
        return uuid
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {

    public func providerDidReset(_ provider: CXProvider) {
        callUUIDs.removeAll()
        onAudioSessionDeactivated?()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let callID = callID(for: action.callUUID) {
            onAnswerCall?(callID)
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let callID = callID(for: action.callUUID) {
            callUUIDs.removeValue(forKey: callID)
            onEndCall?(callID)
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onAudioSessionActivated?()
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        onAudioSessionDeactivated?()
    }
}
#endif
