import XCTest
@testable import VeuCryptoTests

fileprivate extension BurnTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__BurnTests = [
        ("testAfterBurnIsBurnedReturnsTrue", testAfterBurnIsBurnedReturnsTrue),
        ("testBurnAllMarksManyIDsAsBurned", testBurnAllMarksManyIDsAsBurned),
        ("testDerivedKeyIsDeterministic", testDerivedKeyIsDeterministic),
        ("testDifferentArtifactIDsProduceDifferentKeys", testDifferentArtifactIDsProduceDifferentKeys),
        ("testUnburnedIdReturnsFalse", testUnburnedIdReturnsFalse)
    ]
}

fileprivate extension GlazeSeedTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__GlazeSeedTests = [
        ("testDifferentCiphertextsProduceDifferentSeeds", testDifferentCiphertextsProduceDifferentSeeds),
        ("testDifferentSaltsProduceDifferentSeeds", testDifferentSaltsProduceDifferentSeeds),
        ("testGlazeColorChannelsAreNormalized", testGlazeColorChannelsAreNormalized),
        ("testGlazeColorFallbackOnShortSeed", testGlazeColorFallbackOnShortSeed),
        ("testGlazeColorIsDeterministic", testGlazeColorIsDeterministic),
        ("testSameCiphertextAndSaltProduceSameSeed", testSameCiphertextAndSaltProduceSameSeed),
        ("testSeedIsAlways32Bytes", testSeedIsAlways32Bytes)
    ]
}

fileprivate extension ScrambleTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__ScrambleTests = [
        ("testArtifactSerializationRoundTrip", testArtifactSerializationRoundTrip),
        ("testDifferentKeysProduceDifferentCiphertexts", testDifferentKeysProduceDifferentCiphertexts),
        ("testRoundTrip", testRoundTrip),
        ("testRoundTripEmptyData", testRoundTripEmptyData),
        ("testTamperDetectionThrowsDecryptionFailed", testTamperDetectionThrowsDecryptionFailed)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __VeuCryptoTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(BurnTests.__allTests__BurnTests),
        testCase(GlazeSeedTests.__allTests__GlazeSeedTests),
        testCase(ScrambleTests.__allTests__ScrambleTests)
    ]
}