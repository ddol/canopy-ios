// swift-tools-version: 6.0
import PackageDescription

// Game Center sign-in and the local player.
let package = Package(
    name: "CanopyPlayers",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "CanopyPlayers", targets: ["CanopyPlayers"])
    ],
    dependencies: [
        .package(path: "../CanopyModel")
    ],
    targets: [
        .target(
            name: "CanopyPlayers",
            dependencies: [.product(name: "CanopyModel", package: "CanopyModel")]
        ),
        .testTarget(name: "CanopyPlayersTests", dependencies: ["CanopyPlayers"]),
    ]
)
