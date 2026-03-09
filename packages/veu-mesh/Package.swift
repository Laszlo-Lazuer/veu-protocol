// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeuMesh",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VeuMesh",
            targets: ["VeuMesh"]
        )
    ],
    dependencies: [
        .package(name: "VeuCrypto", path: "../veu-crypto"),
        .package(name: "VeuAuth", path: "../veu-auth"),
        .package(name: "VeuGhost", path: "../veu-ghost"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "VeuMesh",
            dependencies: [
                .product(name: "VeuCrypto", package: "VeuCrypto"),
                .product(name: "VeuAuth", package: "VeuAuth"),
                .product(name: "VeuGhost", package: "VeuGhost"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/VeuMesh"
        ),
        .testTarget(
            name: "VeuMeshTests",
            dependencies: ["VeuMesh"],
            path: "Tests/VeuMeshTests"
        )
    ]
)
