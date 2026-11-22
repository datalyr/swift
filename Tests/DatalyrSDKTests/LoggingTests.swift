import XCTest
@testable import DatalyrSDK

/// W3: with debug off, a release app's console stays quiet. Only one-off configuration
/// mistakes found at initialize still print.
final class LoggingTests: XCTestCase {

    private final class Lines {
        private let lock = NSLock()
        private var _all: [String] = []
        func append(_ line: String) { lock.withLock { _all.append(line) } }
        var all: [String] { lock.withLock { _all } }
        func containing(_ text: String) -> [String] { all.filter { $0.contains(text) } }
    }

    private var lines = Lines()
    private var savedWrite: ((String) -> Void)!

    override func setUp() {
        super.setUp()
        lines = Lines()
        savedWrite = DatalyrLogOutput.write
        let lines = self.lines
        DatalyrLogOutput.write = { lines.append($0) }
    }

    override func tearDown() {
        DatalyrLogOutput.write = savedWrite
        super.tearDown()
    }

    func testErrorLogIsSilentWithDebugOff() throws {
        try XCTSkipIf(DatalyrSDK.shared.config?.debug == true, "the shared instance runs with debug on")
        errorLog("w3-error-probe")
        errorLog("w3-error-probe-with-error", error: NSError(domain: "t", code: 1))
        XCTAssertTrue(lines.containing("w3-error-probe").isEmpty, "\(lines.all)")
    }

    func testMisuseLogPrintsWithDebugOff() {
        misuseLog("w3-misuse-probe")
        XCTAssertEqual(lines.containing("w3-misuse-probe").count, 1)
    }

    func testAppleSearchAdsErrorIsSilentWithDebugOff() {
        let asa = AppleSearchAdsIntegration() // debug defaults to false
        asa.logError("w3-asa-probe")
        XCTAssertTrue(lines.containing("w3-asa-probe").isEmpty, "\(lines.all)")
    }

    func testTrackPurchaseWithoutSkadTemplateIsSilentWithDebugOff() async throws {
        try XCTSkipIf(DatalyrSDK.shared.config?.debug == true, "the shared instance runs with debug on")
        let manager = AttributionManager()
        await manager.initialize()
        let sdk = DatalyrSDK()
        sdk.configureForDeferredLookupTesting(
            config: DatalyrConfig(apiKey: "dk_test"),
            attributionManager: manager,
            platformIntegrationManager: PlatformIntegrationManager()
        )
        await sdk.trackPurchase(value: 4.99, currency: "USD")
        await sdk.trackSubscription(value: 9.99, currency: "USD")
        XCTAssertTrue(lines.containing("skadTemplate").isEmpty, "\(lines.all)")
    }
}
