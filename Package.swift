// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LongExposureKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "LongExposureKit",
            targets: ["LongExposureKit"]
        ),
    ],
    targets: [
        .target(name: "LongExposureKit"),
        .testTarget(
            name: "LongExposureKitTests",
            dependencies: ["LongExposureKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
