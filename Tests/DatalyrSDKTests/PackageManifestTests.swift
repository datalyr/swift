import XCTest

/// W9: Package.swift declares only the platforms the SDK is built and tested for.
final class PackageManifestTests: XCTestCase {

    private func manifest() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPackageDeclaresIOS13Only() throws {
        let text = try manifest()
        XCTAssertTrue(text.contains(".iOS(.v13)"))
        for other in [".macOS(", ".tvOS(", ".watchOS(", ".visionOS(", ".macCatalyst("] {
            XCTAssertFalse(text.contains(other), "Package.swift declares \(other) but CI builds iOS only")
        }
    }

    func testPodspecIsIOSOnlyToo() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DatalyrSDK.podspec")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("s.ios.deployment_target = '13.0'"))
        for other in ["s.osx.", "s.tvos.", "s.watchos.", "s.visionos."] {
            XCTAssertFalse(text.contains(other))
        }
    }
}
