// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeuCrypto",
    platforms: [
        .iOS("26.0"),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VeuCrypto",
            targets: ["VeuCrypto"]
        )
    ],
    dependencies: [
        // swift-crypto provides CryptoKit-compatible APIs on Linux.
        // On Apple platforms the native CryptoKit framework is used instead.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "VeuCrypto",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/VeuCrypto"
        ),
        .testTarget(
            name: "VeuCryptoTests",
            dependencies: ["VeuCrypto"],
            path: "Tests/VeuCryptoTests"
        )
    ]
)
