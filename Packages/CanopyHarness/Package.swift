// swift-tools-version: 6.0
import PackageDescription

// A stand-in Gerardus server on the loopback interface, a synthetic park with known trees for it to serve, and the
// benchmarks that load from it. The server speaks the same gRPC over HTTP/1.1 as the real one and can slow itself
// down to a phone's link, so loading real trees can be measured and regression-tested without a server or a park.
let package = Package(
    name: "CanopyHarness",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanopyHarness", targets: ["CanopyHarness"]),
        .executable(name: "canopy-harness", targets: ["canopy-harness"]),
    ],
    dependencies: [
        .package(path: "../CanopyModel"),
        .package(path: "../CanopyReference"),
        .package(path: "../CanopyStore"),
    ],
    targets: [
        .target(
            name: "CanopyHarness",
            dependencies: [
                .product(name: "CanopyModel", package: "CanopyModel"),
                .product(name: "CanopyReference", package: "CanopyReference"),
                .product(name: "CanopyStore", package: "CanopyStore"),
            ],
            // The synthetic park is a million points; unoptimised it takes seconds to build and to serve.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "canopy-harness",
            dependencies: ["CanopyHarness"],
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(name: "CanopyHarnessTests", dependencies: ["CanopyHarness"]),
    ]
)
