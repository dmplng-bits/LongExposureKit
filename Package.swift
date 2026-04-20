// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LongExposureKit",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "LongExposureKit",
            targets: ["LongExposureKit"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "LongExposureKit"
        ),
        .testTarget(
            name: "LongExposureKitTests",
            dependencies: ["LongExposureKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
