// swift-tools-version: 6.0
import PackageDescription

// The boundary to a Gerardus server, an in-memory fake, and a real server's status page over URLSession.
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
