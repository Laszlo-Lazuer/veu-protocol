import Foundation

/// Shared sizing rules for websocket relay messages.
public enum RelayTransportEnvelope {
    public static let maxMessageSize = 10 * 1024 * 1024
    public static let maxPayloadSize = 5 * 1024 * 1024

    public static func encodedPayloadSize(for envelope: Data) -> Int {
        envelope.base64EncodedString().utf8.count
    }

    public static func encodedPackageSize(for envelope: Data, cid: String, topic: String, persist: Bool) -> Int {
        let payload = RelayMessage.ArtifactPushPayload(
            cid: cid,
            topic: topic,
            payload: envelope.base64EncodedString(),
            persist: persist
        )
        let message = RelayMessage.artifactPush(payload)
        return (try? JSONEncoder().encode(message).count) ?? 0
    }
}
