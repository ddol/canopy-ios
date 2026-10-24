// swift-tools-version: 6.0
import PackageDescription

// A Gerardus server over gRPC. The align service (gerardus.align.v1alpha1): USGS 3DEP aerial points, building
// outlines and the ground model per L16 site, tree detection on them, and registering a phone's LiDAR scan against
// 3DEP. The map service (gerardus.map.v1alpha1): the shared tree census as changesets, behind CanopySync's
// GerardusClient. gRPC over URLSession with a hand-written protobuf codec; no third-party dependencies.
let package = Package(
    name: "CanopyReference",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanopyReference", targets: ["CanopyReference"])
    ],
    dependencies: [
        .package(path: "../CanopyModel"),
        .package(path: "../CanopySync"),
    ],
    targets: [
        .target(
            name: "CanopyReference",
            dependencies: [
                .product(name: "CanopyModel", package: "CanopyModel"),
                .product(name: "CanopySync", package: "CanopySync"),
            ],
            // Tree detection walks a million-cell raster; unoptimised it takes seconds per site on a phone.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(name: "CanopyReferenceTests", dependencies: ["CanopyReference"]),
    ]
)
