// CallKitManager.swift — Veu Protocol: Native iOS call UI via CallKit
//
// Provides native incoming call notifications (lock screen), outgoing call
// UI integration, and audio session management tied to CallKit lifecycle.
// Only used for 1:1 calls — circle voice rooms bypass CallKit.

#if canImport(CallKit)
import CallKit
import AVFoundation

/// Bridges VoiceCallManager to the native iOS call UI.
public final class CallKitManager: NSObject, ObservableObject {

    private let provider: CXProvider
    private let callController = CXCallController()

    /// Called when user answers incoming call via CallKit UI.
    public var onAnswerCall: ((UUID) -> Void)?
    /// Called when user ends call via CallKit UI.
    public var onEndCall: ((UUID) -> Void)?
    /// Called when audio session should be configured.
    public var onAudioSessionActivated: (() -> Void)?
    /// Called when audio session is deactivated.
    public var onAudioSessionDeactivated: (() -> Void)?

    /// Map of callID strings to CallKit UUIDs.
    private var callUUIDs: [String: UUID] = [:]

    public override init() {
        let config = CXProviderConfiguration(localizedName: "Veu")
        config.supportsVideo = false
        config.maximumCallGroups = 1
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
    /// - Parameters:
    ///   - callID: The voice call's unique identifier string.
    ///   - callerName: Display name for the caller.
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

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("[CallKit] Failed to report incoming call: \(error)")
            }
            completion?(error)
        }
    }

    // MARK: - Outgoing Call

    /// Start an outgoing call via CallKit.
    public func startOutgoingCall(callID: String, recipientName: String) {
        let uuid = uuidFor(callID: callID)
        let handle = CXHandle(type: .generic, value: recipientName)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = false

        callController.request(CXTransaction(action: startAction)) { error in
            if let error = error {
                print("[CallKit] Failed to start outgoing call: \(error)")
                return
            }
            // Mark the call as connected when the peer answers
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

    /// Report that a call ended (remote hangup or error).
    public func reportCallEnded(callID: String, reason: CXCallEndedReason) {
        guard let uuid = callUUIDs[callID] else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        callUUIDs.removeValue(forKey: callID)
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
        let callID = callUUIDs.first(where: { $0.value == action.callUUID })?.key
        if let callID = callID {
            onAnswerCall?(action.callUUID)
            _ = callID  // Keep for logging if needed
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let callID = callUUIDs.first(where: { $0.value == action.callUUID })?.key
        onEndCall?(action.callUUID)
        if let callID = callID {
            callUUIDs.removeValue(forKey: callID)
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        // VoiceCallManager handles mute state directly
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
