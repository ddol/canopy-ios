// swift-tools-version: 6.0
import PackageDescription

// Value types shared by every other package. No dependencies; also builds on macOS so `swift test` is quick.
let package = Package(
    name: "CanopyModel",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanopyModel", targets: ["CanopyModel"])
    ],
    targets: [
        .target(name: "CanopyModel"),
        .testTarget(name: "CanopyModelTests", dependencies: ["CanopyModel"], exclude: ["S2Vectors.md"]),
    ]
)
