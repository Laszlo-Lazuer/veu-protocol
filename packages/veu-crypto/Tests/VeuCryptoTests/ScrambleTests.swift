import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import VeuCrypto

final class ScrambleTests: XCTestCase {

    // MARK: - Round-trip

    func testRoundTrip() throws {
        let key      = SymmetricKey(size: .bits256)
        let original = Data("Hello, Veu protocol!".utf8)

        let artifact  = try Scramble.scramble(data: original, using: key)
        let recovered = try Scramble.unscramble(artifact: artifact, using: key)

        XCTAssertEqual(original, recovered)
    }

    func testRoundTripEmptyData() throws {
        let key      = SymmetricKey(size: .bits256)
        let original = Data()

        let artifact  = try Scramble.scramble(data: original, using: key)
        let recovered = try Scramble.unscramble(artifact: artifact, using: key)

        XCTAssertEqual(original, recovered)
    }

    // MARK: - Tamper detection

    func testTamperDetectionThrowsDecryptionFailed() throws {
        let key      = SymmetricKey(size: .bits256)
        let plaintext = Data("Sensitive content".utf8)

        let artifact = try Scramble.scramble(data: plaintext, using: key)

        // Flip a bit in the ciphertext.
        var tamperedCiphertext = artifact.ciphertext
        tamperedCiphertext[tamperedCiphertext.startIndex] ^= 0xFF

        let tamperedArtifact = VeuArtifact(iv: artifact.iv,
                                           tag: artifact.tag,
                                           ciphertext: tamperedCiphertext)

        XCTAssertThrowsError(try Scramble.unscramble(artifact: tamperedArtifact, using: key)) { error in
            XCTAssertEqual(error as? VeuCryptoError, VeuCryptoError.decryptionFailed)
        }
    }

    // MARK: - Different keys → different ciphertexts

    func testDifferentKeysProduceDifferentCiphertexts() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let data = Data("Same plaintext".utf8)

        let artifact1 = try Scramble.scramble(data: data, using: key1)
        let artifact2 = try Scramble.scramble(data: data, using: key2)

        XCTAssertNotEqual(artifact1.ciphertext, artifact2.ciphertext)
    }

    // MARK: - Artifact serialisation round-trip

    func testArtifactSerializationRoundTrip() throws {
        let key      = SymmetricKey(size: .bits256)
        let original = Data("Serialisation test".utf8)

        let artifact    = try Scramble.scramble(data: original, using: key)
        let bytes       = artifact.serialized()
        let reparsed    = try VeuArtifact(from: bytes)
        let recovered   = try Scramble.unscramble(artifact: reparsed, using: key)

        XCTAssertEqual(original, recovered)
    }
}
