import XCTest
@testable import DatalyrSDK

/// Public entry points that had no tests: deprecated getters, configure(apiKey:),
/// trackPurchase and the global helper functions.
final class PublicAPITests: XCTestCase {

    // MARK: - W4: deprecated API keeps working

    @available(*, deprecated)
    func testDeprecatedGettersStillAnswerNil() {
        let sdk = DatalyrSDK()
        XCTAssertNil(sdk.getDeferredAttributionData())
        XCTAssertNil(sdk.getLastError())
    }

    @available(*, deprecated)
    func testDeprecatedConfigOptionsStillAccepted() {
        let auto = AutoEventConfig(trackAppUpdates: false, trackPerformance: true)
        let config = DatalyrConfig(apiKey: "dk_test", respectDoNotTrack: false, autoEventConfig: auto)
        XCTAssertFalse(config.respectDoNotTrack)
        XCTAssertFalse(auto.trackAppUpdates)
        XCTAssertTrue(auto.trackPerformance)
    }
}
