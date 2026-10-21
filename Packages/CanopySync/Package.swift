// swift-tools-version: 6.0
import PackageDescription

// The boundary to a Gerardus server, plus an in-memory fake. No network code yet.
let package = Package(
    name: "CanopySync",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanopySync", targets: ["CanopySync"])
    ],
    dependencies: [
        .package(path: "../CanopyModel")
    ],
    targets: [
        .target(
            name: "CanopySync",
            dependencies: [.product(name: "CanopyModel", package: "CanopyModel")]
        ),
        .testTarget(name: "CanopySyncTests", dependencies: ["CanopySync"]),
    ]
)
