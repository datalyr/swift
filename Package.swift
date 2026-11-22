// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "DatalyrSDK",
    // iOS only, like the podspec and CI. Other platforms were declared but never
    // built: DatalyrUtils.swift imports AdSupport and AppTrackingTransparency
    // without a platform guard.
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
