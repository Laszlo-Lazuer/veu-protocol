// GhostMessageTests.swift — Veu Protocol: Message Serialization Tests

import XCTest
@testable import VeuGhost

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class GhostMessageTests: XCTestCase {

    /// A fixed 32-byte Circle Key for tests.
    private var circleKey: Data {
        Data(repeating: 0xAA, count: 32)
    }

    // MARK: - Codable Round-Trip

    func testSyncRequestCodable() throws {
        let msg = GhostMessage.syncRequest(
            GhostMessage.SyncRequestPayload(
                deviceID: "device-1",
                vectorClock: VectorClock(state: ["device-1": 5, "device-2": 3]),
                circleID: "circle-abc"
            )
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(GhostMessage.self, from: data)
        XCTAssertEqual(msg, decoded)
    }

    func testSyncResponseCodable() throws {
        let msg = GhostMessage.syncResponse(
            GhostMessage.SyncResponsePayload(
                deviceID: "device-2",
                vectorClock: VectorClock(state: ["device-1": 5]),
                artifactCount: 3
            )
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(GhostMessage.self, from: data)
        XCTAssertEqual(msg, decoded)
    }

    func testArtifactPushCodable() throws {
        let msg = GhostMessage.artifactPush(
            GhostMessage.ArtifactPushPayload(
                cid: "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
                circleID: "circle-abc",
                artifactType: "post",
                encryptedMeta: Data([1, 2, 3, 4]),
                sequence: 42,
                originDeviceID: "device-1",
                burnAfter: 1700000000
            )
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(GhostMessage.self, from: data)
        XCTAssertEqual(msg, decoded)
    }

    func testBurnNoticeCodable() throws {
        let msg = GhostMessage.burnNotice(
            GhostMessage.BurnNoticePayload(
                cid: "bafytest123",
                circleID: "circle-abc",
                originDeviceID: "device-1"
            )
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(GhostMessage.self, from: data)
        XCTAssertEqual(msg, decoded)
    }

    func testAckCodable() throws {
        let msg = GhostMessage.ack(
            GhostMessage.AckPayload(cid: "bafytest123", deviceID: "device-2")
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(GhostMessage.self, from: data)
        XCTAssertEqual(msg, decoded)
    }

    // MARK: - Envelope Encryption

    func testSealAndOpen() throws {
        let original = GhostMessage.syncRequest(
            GhostMessage.SyncRequestPayload(
                deviceID: "device-1",
                vectorClock: VectorClock(state: ["device-1": 10]),
                circleID: "circle-abc"
            )
        )

        let envelope = try original.seal(with: circleKey)
        XCTAssertGreaterThan(envelope.count, 0)

        let opened = try GhostMessage.open(envelope: envelope, with: circleKey)
        XCTAssertEqual(original, opened)
    }

    func testSealProducesDifferentEnvelopesEachTime() throws {
        let msg = GhostMessage.ack(GhostMessage.AckPayload(cid: "test", deviceID: "d"))
        let e1 = try msg.seal(with: circleKey)
        let e2 = try msg.seal(with: circleKey)
        // AES-GCM uses random nonce, so envelopes should differ
        XCTAssertNotEqual(e1, e2)
    }

    func testOpenWithWrongKeyFails() throws {
        let msg = GhostMessage.ack(GhostMessage.AckPayload(cid: "test", deviceID: "d"))
        let envelope = try msg.seal(with: circleKey)
        let wrongKey = Data(repeating: 0xBB, count: 32)

        XCTAssertThrowsError(try GhostMessage.open(envelope: envelope, with: wrongKey)) { error in
            guard let ghostError = error as? VeuGhostError else {
                XCTFail("Expected VeuGhostError")
                return
            }
            if case .encryptionFailed = ghostError { } else {
                XCTFail("Expected encryptionFailed, got \(ghostError)")
            }
        }
    }

    func testOpenTamperedEnvelopeFails() throws {
        let msg = GhostMessage.ack(GhostMessage.AckPayload(cid: "test", deviceID: "d"))
        var envelope = try msg.seal(with: circleKey)
        // Tamper with a byte in the ciphertext
        if envelope.count > 20 {
            envelope[20] ^= 0xFF
        }

        XCTAssertThrowsError(try GhostMessage.open(envelope: envelope, with: circleKey))
    }

    // MARK: - Circle Topic Hash

    func testCircleTopicHashIsDeterministic() {
        let h1 = GhostConnection.circleTopicHash(circleKey: circleKey)
        let h2 = GhostConnection.circleTopicHash(circleKey: circleKey)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 64) // SHA-256 hex = 64 chars
    }

    func testCircleTopicHashDiffersPerKey() {
        let h1 = GhostConnection.circleTopicHash(circleKey: Data(repeating: 0xAA, count: 32))
        let h2 = GhostConnection.circleTopicHash(circleKey: Data(repeating: 0xBB, count: 32))
        XCTAssertNotEqual(h1, h2)
    }
}
