// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeuApp",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VeuApp",
            targets: ["VeuApp"]
        )
    ],
    dependencies: [
        .package(name: "VeuCrypto", path: "../veu-crypto"),
        .package(name: "VeuAuth", path: "../veu-auth"),
        .package(name: "VeuGlaze", path: "../veu-glaze"),
        .package(name: "VeuGhost", path: "../veu-ghost"),
        .package(name: "VeuMesh", path: "../veu-mesh"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "VeuApp",
            dependencies: [
                .product(name: "VeuCrypto", package: "VeuCrypto"),
                .product(name: "VeuAuth", package: "VeuAuth"),
                .product(name: "VeuGlaze", package: "VeuGlaze"),
                .product(name: "VeuGhost", package: "VeuGhost"),
                .product(name: "VeuMesh", package: "VeuMesh"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/VeuApp"
        ),
        .testTarget(
            name: "VeuAppTests",
            dependencies: ["VeuApp"],
            path: "Tests/VeuAppTests"
        )
    ]
)
