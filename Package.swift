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
        // Reads the ATT status when the SDK is loaded into the app process (before main()).
        .target(
            name: "DatalyrSDKLaunch",
            path: "Sources/DatalyrSDKLaunch"
        ),
        .target(
            name: "DatalyrSDK",
            dependencies: ["DatalyrSDKLaunch"],
            path: "Sources/DatalyrSDK",
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "DatalyrSDKTests",
            dependencies: ["DatalyrSDK"],
            path: "Tests/DatalyrSDKTests"
        ),
    ]
)
