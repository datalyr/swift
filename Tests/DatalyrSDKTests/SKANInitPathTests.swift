import XCTest
@testable import DatalyrSDK

/// C4: initializeWithSKAdNetwork keeps every field of the caller's config and sets only
/// skadTemplate.
final class SKANInitPathTests: XCTestCase {

    @available(*, deprecated) // reads respectDoNotTrack / trackAppUpdates
    func testEveryConfigFieldSurvivesTheSKANPath() {
        let auto = AutoEventConfig(trackSessions: false, trackScreenViews: false, trackAppUpdates: false,
                                   trackPerformance: true, sessionTimeoutMs: 1234, autoTrackScreenViews: true)
        let original = DatalyrConfig(
            apiKey: "dk_test", workspaceId: "ws", useServerTracking: false, debug: true,
            endpoint: "https://example.invalid/track", maxRetries: 7, retryDelay: 2.5, timeout: 9,
            batchSize: 3, flushInterval: 42, maxQueueSize: 77, respectDoNotTrack: false,
            enableAutoEvents: false, enableAttribution: false, autoEventConfig: auto,
            skadTemplate: nil, existingUserHint: { true }
        )

        let c = DatalyrSDK.skadConfig(from: original, template: "gaming")

        XCTAssertEqual(c.skadTemplate, "gaming")
        XCTAssertEqual(c.apiKey, "dk_test")
        XCTAssertEqual(c.workspaceId, "ws")
        XCTAssertFalse(c.useServerTracking)
        XCTAssertTrue(c.debug)
        XCTAssertEqual(c.endpoint, "https://example.invalid/track")
        XCTAssertEqual(c.maxRetries, 7)
        XCTAssertEqual(c.retryDelay, 2.5)
        XCTAssertEqual(c.timeout, 9)
        XCTAssertEqual(c.batchSize, 3)
        XCTAssertEqual(c.flushInterval, 42)
        XCTAssertEqual(c.maxQueueSize, 77)
        XCTAssertFalse(c.respectDoNotTrack)
        XCTAssertFalse(c.enableAutoEvents)
        XCTAssertFalse(c.enableAttribution)
        XCTAssertEqual(c.autoEventConfig?.trackSessions, false)
        XCTAssertEqual(c.autoEventConfig?.trackScreenViews, false)
        XCTAssertEqual(c.autoEventConfig?.trackAppUpdates, false)
        XCTAssertEqual(c.autoEventConfig?.trackPerformance, true)
        XCTAssertEqual(c.autoEventConfig?.sessionTimeoutMs, 1234)
        XCTAssertEqual(c.autoEventConfig?.autoTrackScreenViews, true)
        XCTAssertEqual(c.existingUserHint?(), true)
        XCTAssertNil(original.skadTemplate, "the caller's config is not changed")
    }

    func testSKANInitRejectsAnEmptyKeyLikeInitialize() async {
        // Compile-and-call for both SKAN entry points; an empty key throws before any state changes.
        for call in [
            { try await DatalyrSDK.initializeWithSKAdNetwork(config: DatalyrConfig(apiKey: "")) },
            { try await DatalyrSDK.initializeWithSKAdNetwork(config: DatalyrConfig(apiKey: ""), template: "subscription") },
            { try await DatalyrSDK.configureWithSKAdNetwork(apiKey: "") },
            { try await DatalyrSDK.configureWithSKAdNetwork(apiKey: "", workspaceId: "ws", template: "gaming",
                                                           debug: false, enableAutoEvents: false, enableAttribution: false) },
        ] as [() async throws -> Void] {
            do {
                try await call()
                XCTFail("expected invalidConfiguration")
            } catch DatalyrError.invalidConfiguration(_) {
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(DatalyrSDK.shared.isInitialized)
    }
}
