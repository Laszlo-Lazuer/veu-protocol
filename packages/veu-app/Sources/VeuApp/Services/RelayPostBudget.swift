import Foundation
import VeuAuth
import VeuCrypto
import VeuGhost
import VeuMesh

public enum RelayPostBudget {
    public static let targetEncodedPackageBytes = 2 * 1024 * 1024

    public static func encodedPackageSize(
        forPostData postData: Data,
        circleID: String,
        circleKey: CircleKey,
        senderDeviceID: String,
        burnAfter: Int? = nil,
        targetRecipients: [String]? = nil
    ) throws -> Int {
        let artifact = try Scramble.scramble(data: postData, using: circleKey.symmetricKey)
        let encryptedMeta = artifact.serialized()
        let message = GhostMessage.artifactPush(
            GhostMessage.ArtifactPushPayload(
                cid: UUID().uuidString,
                circleID: circleID,
                artifactType: "post",
                encryptedMeta: encryptedMeta,
                sequence: 1,
                originDeviceID: senderDeviceID,
                burnAfter: burnAfter,
                targetRecipients: targetRecipients
            )
        )
        let envelope = try message.seal(with: circleKey.keyData)
        let topicHash = GhostConnection.circleTopicHash(circleKey: circleKey.keyData)
        return RelayTransportEnvelope.encodedPackageSize(for: envelope, cid: UUID().uuidString, topic: topicHash, persist: true)
    }
}
