// swift-tools-version: 6.0
import PackageDescription

// Reference data and registration from a Gerardus align server (gerardus.align.v1alpha1): USGS 3DEP aerial
// points, OpenStreetMap features and the ground model per L16 site, tree detection on them, and registering a
// phone's LiDAR scan against 3DEP. gRPC over URLSession with a hand-written protobuf codec; no dependencies.
let package = Package(
    name: "CanopyReference",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanopyReference", targets: ["CanopyReference"])
    ],
    dependencies: [
        .package(path: "../CanopyModel")
    ],
    targets: [
        .target(
            name: "CanopyReference",
            dependencies: [.product(name: "CanopyModel", package: "CanopyModel")],
            // Tree detection walks a million-cell raster; unoptimised it takes seconds per site on a phone.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(name: "CanopyReferenceTests", dependencies: ["CanopyReference"]),
    ]
)
