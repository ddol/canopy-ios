// swift-tools-version: 6.0
import PackageDescription

// ARKit capture (iOS only) and the pure geometry it relies on (GLB writer, circle fit), which also
// builds on macOS so it can be tested without a device.
let package = Package(
    name: "CanopyCapture",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanopyCapture", targets: ["CanopyCapture"])
    ],
    dependencies: [
        .package(path: "../CanopyModel")
    ],
    targets: [
        .target(
            name: "CanopyCapture",
            dependencies: [.product(name: "CanopyModel", package: "CanopyModel")]
        ),
        .testTarget(name: "CanopyCaptureTests", dependencies: ["CanopyCapture"]),
    ]
)
