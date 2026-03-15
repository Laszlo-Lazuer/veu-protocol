import XCTest
@testable import VeuApp
import VeuAuth
import VeuCrypto

final class RelayDefaultsTests: XCTestCase {
    func testEffectiveRelayURLFallsBackToDefaultForBlankValues() {
        XCTAssertEqual(
            RelayDefaults.effectiveRelayURL(from: nil)?.absoluteString,
            RelayDefaults.defaultRelayURLString
        )
        XCTAssertEqual(
            RelayDefaults.effectiveRelayURL(from: "   ")?.absoluteString,
            RelayDefaults.defaultRelayURLString
        )
    }

    func testEffectiveRelayURLUsesCustomValueWhenProvided() {
        XCTAssertEqual(
            RelayDefaults.effectiveRelayURL(from: "wss://custom.example/ws")?.absoluteString,
            "wss://custom.example/ws"
        )
    }

    func testEffectiveRelayURLRejectsInvalidNonBlankValues() {
        XCTAssertNil(RelayDefaults.effectiveRelayURL(from: "not a url"))
    }

    func testRelayPostBudgetGrowsWithPayloadSize() throws {
        let circleKey = CircleKey(
            keyData: Data(repeating: 0x11, count: 32),
            glazeSalt: Data(repeating: 0x22, count: 16)
        )

        let small = try RelayPostBudget.encodedPackageSize(
            forPostData: Data(repeating: 0x01, count: 64),
            circleID: "circle-1",
            circleKey: circleKey,
            senderDeviceID: "device-1"
        )
        let large = try RelayPostBudget.encodedPackageSize(
            forPostData: Data(repeating: 0x01, count: 4096),
            circleID: "circle-1",
            circleKey: circleKey,
            senderDeviceID: "device-1"
        )

        XCTAssertGreaterThan(large, small)
    }
}
