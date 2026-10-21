// swift-tools-version: 6.0
import PackageDescription

// Design tokens and base components. iOS only (dynamic colours use UIKit traits).
let package = Package(
    name: "CanopyDesign",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "CanopyDesign", targets: ["CanopyDesign"])
    ],
    targets: [
        .target(name: "CanopyDesign"),
        .testTarget(name: "CanopyDesignTests", dependencies: ["CanopyDesign"]),
    ]
)
