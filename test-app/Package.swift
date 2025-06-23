// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "DatalyrTestApp",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .executable(
            name: "DatalyrTestApp",
            targets: ["DatalyrTestApp"]
        ),
    ],
    dependencies: [
        .package(path: "../")
    ],
    targets: [
        .executableTarget(
            name: "DatalyrTestApp",
            dependencies: [
                .product(name: "DatalyrSDK", package: "DatalyrSDK")
            ],
            path: "Sources"
        ),
    ]
) 