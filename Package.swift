// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "DatalyrSDK",
    // The SDK is built and tested for iOS only, like the podspec and CI.
    // SwiftPM cannot exclude a platform: one left out here gets the SDK's oldest
    // deployment target, not a resolution error. macOS, tvOS and watchOS were
    // listed before but never built (DatalyrUtils.swift imports AdSupport and
    // AppTrackingTransparency without a platform guard).
    platforms: [
        .iOS(.v13)
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
