// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeuAuth",
    platforms: [
        .iOS("26.0"),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VeuAuth",
            targets: ["VeuAuth"]
        )
    ],
    dependencies: [
        .package(name: "VeuCrypto", path: "../veu-crypto"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "VeuAuth",
            dependencies: [
                .product(name: "VeuCrypto", package: "VeuCrypto"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/VeuAuth"
        ),
        .testTarget(
            name: "VeuAuthTests",
            dependencies: ["VeuAuth"],
            path: "Tests/VeuAuthTests"
        )
    ]
)
