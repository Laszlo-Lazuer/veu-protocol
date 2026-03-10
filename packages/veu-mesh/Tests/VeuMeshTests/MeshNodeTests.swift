// MeshNodeTests.swift — Veu Protocol: MeshNode + Transport Tests

import XCTest
@testable import VeuMesh
import VeuGhost
import VeuAuth

final class MeshNodeTests: XCTestCase {

    private func makeLedger() throws -> Ledger {
        let ledger = try Ledger(path: ":memory:")
        try ledger.initializeMeta(deviceID: "test-device")
        return ledger
    }

    private var circleKey: Data { Data(repeating: 0xDD, count: 32) }

    // MARK: - MeshNode Lifecycle

    func testMeshNodeCreation() throws {
        let ledger = try makeLedger()
        let node = MeshNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        XCTAssertEqual(node.circleID, "circle-abc")
        XCTAssertFalse(node.isRunning)
        XCTAssertNil(node.activeTransportName)
    }

    func testMeshNodeWithRelayURL() throws {
        let ledger = try makeLedger()
        let node = MeshNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger,
            relayURL: URL(string: "wss://relay.example.com/ws")!
        )

        XCTAssertEqual(node.relayURL?.absoluteString, "wss://relay.example.com/ws")
    }

    func testGhostNodeAccessible() throws {
        let ledger = try makeLedger()
        let node = MeshNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        XCTAssertEqual(node.ghostNode.deviceID, "device-1")
        XCTAssertEqual(node.ghostNode.circleID, "circle-abc")
    }

    func testStopClearsTransports() throws {
        let ledger = try makeLedger()
        let node = MeshNode(
            deviceID: "device-1",
            circleID: "circle-abc",
            circleKey: circleKey,
            ledger: ledger
        )

        // Start will fail in test environment (no real network), but stop should clean up
        _ = try? node.start()
        node.stop()
        XCTAssertTrue(node.transports.isEmpty)
    }

    // MARK: - MeshRouter

    func testRouterAddRoute() {
        var router = MeshRouter(maxHops: 5)
        router.addRoute(to: "peer-B", via: "peer-A", hops: 1)
        XCTAssertEqual(router.count, 1)
        XCTAssertNotNil(router.route(to: "peer-B"))
    }

    func testRouterPrefersShorterRoute() {
        var router = MeshRouter(maxHops: 5)
        router.addRoute(to: "peer-B", via: "peer-A", hops: 3)
        router.addRoute(to: "peer-B", via: "peer-C", hops: 1)
        let route = router.route(to: "peer-B")
        XCTAssertEqual(route?.via, "peer-C")
        XCTAssertEqual(route?.hops, 1)
    }

    func testRouterDoesNotReplaceWithLongerRoute() {
        var router = MeshRouter(maxHops: 5)
        router.addRoute(to: "peer-B", via: "peer-A", hops: 1)
        router.addRoute(to: "peer-B", via: "peer-C", hops: 3)
        let route = router.route(to: "peer-B")
        XCTAssertEqual(route?.via, "peer-A")
    }

    func testRouterRejectsOverMaxHops() {
        var router = MeshRouter(maxHops: 3)
        router.addRoute(to: "peer-B", via: "peer-A", hops: 4)
        XCTAssertNil(router.route(to: "peer-B"))
        XCTAssertEqual(router.count, 0)
    }

    func testRouterRemoveRoute() {
        var router = MeshRouter(maxHops: 5)
        router.addRoute(to: "peer-B", via: "peer-A", hops: 1)
        router.addRoute(to: "peer-C", via: "peer-B", hops: 2)
        router.removeRoute(to: "peer-B")
        // Should remove peer-B and all routes via peer-B
        XCTAssertNil(router.route(to: "peer-B"))
        XCTAssertNil(router.route(to: "peer-C"))
    }

    func testRouterDestinations() {
        var router = MeshRouter(maxHops: 5)
        router.addRoute(to: "peer-A", via: "direct", hops: 1)
        router.addRoute(to: "peer-B", via: "peer-A", hops: 2)
        XCTAssertEqual(Set(router.destinations), Set(["peer-A", "peer-B"]))
    }

    // MARK: - VeuMeshError

    func testErrorEquatable() {
        XCTAssertEqual(VeuMeshError.noTransportAvailable, VeuMeshError.noTransportAvailable)
        XCTAssertEqual(VeuMeshError.transportFailed("x"), VeuMeshError.transportFailed("x"))
        XCTAssertNotEqual(VeuMeshError.transportFailed("x"), VeuMeshError.transportFailed("y"))
        XCTAssertNotEqual(VeuMeshError.noTransportAvailable, VeuMeshError.transportFailed("x"))
    }

    // MARK: - LocalTransport

    func testLocalTransportCreation() {
        let transport = LocalTransport(circleKey: circleKey)
        XCTAssertEqual(transport.name, "Local")
        XCTAssertFalse(transport.isAvailable)
        XCTAssertEqual(transport.state, .disconnected)
    }

    func testLocalTransportStartAndStop() throws {
        let transport = LocalTransport(circleKey: circleKey)
        try transport.start()
        XCTAssertTrue(transport.isAvailable)
        XCTAssertEqual(transport.state, .connected)
        transport.stop()
        XCTAssertFalse(transport.isAvailable)
        XCTAssertEqual(transport.state, .disconnected)
    }

    // MARK: - MeshTransport

    func testMeshTransportCreation() {
        let transport = MeshTransport(circleKey: circleKey, deviceName: "test-device")
        XCTAssertEqual(transport.name, "Mesh")
        XCTAssertFalse(transport.isAvailable)
    }

    func testMeshTransportMaxHops() {
        XCTAssertEqual(MeshTransport.maxHops, 5)
    }

    // MARK: - GlobalTransport

    func testGlobalTransportCreation() {
        let transport = GlobalTransport(
            relayURL: URL(string: "wss://relay.example.com/ws")!,
            circleKey: circleKey,
            deviceID: "device-1"
        )
        XCTAssertEqual(transport.name, "Global")
        XCTAssertFalse(transport.isAvailable)
        XCTAssertEqual(transport.state, .disconnected)
    }

    func testGlobalTransportTopicHash() {
        let transport = GlobalTransport(
            relayURL: URL(string: "wss://relay.example.com/ws")!,
            circleKey: circleKey,
            deviceID: "device-1"
        )
        let expected = GhostConnection.circleTopicHash(circleKey: circleKey)
        XCTAssertEqual(transport.topicHash, expected)
    }

    func testGlobalTransportPushToken() {
        let transport = GlobalTransport(
            relayURL: URL(string: "wss://relay.example.com/ws")!,
            circleKey: circleKey,
            deviceID: "device-1"
        )
        XCTAssertNil(transport.pushToken)
        transport.pushToken = "abc123"
        XCTAssertEqual(transport.pushToken, "abc123")
    }

    // MARK: - MeshTransportState

    func testMeshTransportStateEquatable() {
        XCTAssertEqual(MeshTransportState.disconnected, MeshTransportState.disconnected)
        XCTAssertEqual(MeshTransportState.connected, MeshTransportState.connected)
        XCTAssertEqual(MeshTransportState.connecting, MeshTransportState.connecting)
        XCTAssertEqual(MeshTransportState.failed("x"), MeshTransportState.failed("x"))
        XCTAssertNotEqual(MeshTransportState.connected, MeshTransportState.disconnected)
    }

    // MARK: - RelayMessage Codable

    func testRelayMessageArtifactPushCodable() throws {
        let msg = RelayMessage.artifactPush(
            RelayMessage.ArtifactPushPayload(cid: "bafktest", topic: "abcdef1234", payload: "base64data")
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: data)
        if case .artifactPush(let p) = decoded {
            XCTAssertEqual(p.cid, "bafktest")
            XCTAssertEqual(p.topic, "abcdef1234")
            XCTAssertEqual(p.payload, "base64data")
        } else {
            XCTFail("Expected artifactPush")
        }
    }

    func testRelayMessagePullRequestCodable() throws {
        let msg = RelayMessage.pullRequest(
            RelayMessage.PullRequestPayload(topic: "abcdef", since: 1700000000)
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: data)
        if case .pullRequest(let p) = decoded {
            XCTAssertEqual(p.topic, "abcdef")
            XCTAssertEqual(p.since, 1700000000)
        } else {
            XCTFail("Expected pullRequest")
        }
    }

    func testRelayMessageRegisterTokenCodable() throws {
        let msg = RelayMessage.registerToken(
            RelayMessage.RegisterTokenPayload(topic: "abcdef", token: "apns-token", deviceID: "dev-1")
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: data)
        if case .registerToken(let p) = decoded {
            XCTAssertEqual(p.topic, "abcdef")
            XCTAssertEqual(p.token, "apns-token")
            XCTAssertEqual(p.deviceID, "dev-1")
        } else {
            XCTFail("Expected registerToken")
        }
    }
}
