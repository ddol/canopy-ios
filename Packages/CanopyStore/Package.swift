// swift-tools-version: 6.0
import PackageDescription

// Local persistence on the system SQLite library, plus a content-addressed blob directory.
let package = Package(
    name: "CanopyStore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanopyStore", targets: ["CanopyStore"])
    ],
    dependencies: [
        .package(path: "../CanopyModel")
    ],
    targets: [
        .target(
            name: "CanopyStore",
            dependencies: [.product(name: "CanopyModel", package: "CanopyModel")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "CanopyStoreTests", dependencies: ["CanopyStore"]),
    ]
)
