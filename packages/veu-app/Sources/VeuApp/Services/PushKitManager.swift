// PushKitManager.swift — Veu Protocol: VoIP push notifications via PushKit
//
// Registers for VoIP push notifications so the app can receive incoming calls
// even when backgrounded or terminated. When a VoIP push arrives, iOS launches
// the app and we must report a CallKit incoming call within the callback.
//
// PREREQUISITES:
// - VoIP push certificate in Apple Developer portal
// - Push Notifications capability enabled in Xcode
// - Background Modes → Voice over IP enabled in Xcode

#if os(iOS)
import Foundation
import PushKit
import CallKit

/// Manages VoIP push registration and incoming push handling.
/// Must be initialized early in app lifecycle (e.g., AppDelegate or @main App.init).
public final class PushKitManager: NSObject, ObservableObject {

    /// The current VoIP push token (hex-encoded). Send to your push server.
    @Published public private(set) var pushToken: String?

    /// Called when a VoIP push arrives with call data.
    /// The handler MUST report a CallKit incoming call before returning.
    public var onIncomingPush: ((_ callID: String, _ callerName: String, _ payload: [AnyHashable: Any]) -> Void)?

    private let registry: PKPushRegistry

    public override init() {
        self.registry = PKPushRegistry(queue: .main)
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }
}

// MARK: - PKPushRegistryDelegate

extension PushKitManager: PKPushRegistryDelegate {

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        pushToken = token
        print("[PushKit] 📱 VoIP push token: \(token.prefix(16))…")
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        let data = payload.dictionaryPayload
        let callID = data["call_id"] as? String ?? UUID().uuidString
        let callerName = data["caller_name"] as? String ?? "Unknown"

        print("[PushKit] 📞 Incoming VoIP push: call=\(callID.prefix(8)), caller=\(callerName)")

        // The app MUST report a CallKit incoming call here or iOS will terminate it.
        // The onIncomingPush handler is responsible for calling CallKitManager.reportIncomingCall().
        onIncomingPush?(callID, callerName, data)

        completion()
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        pushToken = nil
        print("[PushKit] ⚠️ VoIP push token invalidated")
    }
}
#endif
