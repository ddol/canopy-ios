// swift-tools-version: 6.0
import PackageDescription

// The park map behind a renderer protocol, with a MapKit implementation.
let package = Package(
    name: "CanopyMap",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "CanopyMap", targets: ["CanopyMap"])
    ],
    dependencies: [
        .package(path: "../CanopyModel"),
        .package(path: "../CanopyDesign"),
    ],
    targets: [
        .target(
            name: "CanopyMap",
            dependencies: [
                .product(name: "CanopyModel", package: "CanopyModel"),
                .product(name: "CanopyDesign", package: "CanopyDesign"),
            ]
        ),
        .testTarget(name: "CanopyMapTests", dependencies: ["CanopyMap"]),
    ]
)
