// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeuGhost",
    platforms: [
        .iOS("26.0"),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VeuGhost",
            targets: ["VeuGhost"]
        )
    ],
    dependencies: [
        .package(name: "VeuCrypto", path: "../veu-crypto"),
        .package(name: "VeuAuth", path: "../veu-auth"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "VeuGhost",
            dependencies: [
                .product(name: "VeuCrypto", package: "VeuCrypto"),
                .product(name: "VeuAuth", package: "VeuAuth"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/VeuGhost"
        ),
        .testTarget(
            name: "VeuGhostTests",
            dependencies: ["VeuGhost"],
            path: "Tests/VeuGhostTests"
        )
    ]
)
