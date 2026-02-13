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
    dependencies: [
        // Meta (Facebook) SDK - for deferred deep linking and attribution
        .package(url: "https://github.com/facebook/facebook-ios-sdk.git", from: "18.0.0"),
        // TikTok Business SDK - for TikTok attribution and events
        .package(url: "https://github.com/tiktok/tiktok-business-ios-sdk.git", exact: "1.6.0"),
    ],
    targets: [
        .target(
            name: "DatalyrSDK",
            dependencies: [
                // Meta SDK - provides FBSDKCoreKit module for iOS
                .product(name: "FacebookCore", package: "facebook-ios-sdk", condition: .when(platforms: [.iOS])),
                // TikTok SDK - provides TikTokBusinessSDK module for iOS
                .product(name: "TikTokBusinessSDK", package: "tiktok-business-ios-sdk", condition: .when(platforms: [.iOS])),
            ],
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
