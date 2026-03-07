// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeuGlaze",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VeuGlaze",
            targets: ["VeuGlaze"]
        )
    ],
    dependencies: [
        .package(name: "VeuCrypto", path: "../veu-crypto"),
        .package(name: "VeuAuth", path: "../veu-auth"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "VeuGlaze",
            dependencies: [
                .product(name: "VeuCrypto", package: "VeuCrypto"),
                .product(name: "VeuAuth", package: "VeuAuth"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/VeuGlaze"
        ),
        .testTarget(
            name: "VeuGlazeTests",
            dependencies: ["VeuGlaze"],
            path: "Tests/VeuGlazeTests"
        )
    ]
)
