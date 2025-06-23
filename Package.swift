// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "DatalyrSDK",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(
            name: "DatalyrSDK",
            targets: ["DatalyrSDK"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DatalyrSDK",
            dependencies: [],
            path: "Sources/DatalyrSDK"
        ),
        .testTarget(
            name: "DatalyrSDKTests",
            dependencies: ["DatalyrSDK"],
            path: "Tests/DatalyrSDKTests"
        ),
    ]
) 