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

    // MARK: - W18 / W14: configure(apiKey:) — one function, every old call form

    /// An empty key makes initialize throw before it touches any state, so these are
    /// real calls into the shared instance that leave it uninitialized.
    private func assertRejectsEmptyKey(_ call: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await call()
            XCTFail("expected invalidConfiguration", file: file, line: line)
        } catch DatalyrError.invalidConfiguration(_) {
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testConfigureAcceptsEveryOldCallForm() async {
        // Old overload 1: configure(apiKey:workspaceId:debug:)
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "") }
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", workspaceId: "ws") }
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", debug: true) }
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", workspaceId: "ws", debug: false) }
        // Old overload 2: + enableAutoEvents / enableAttribution
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", enableAutoEvents: false) }
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", enableAttribution: false) }
        await assertRejectsEmptyKey {
            try await DatalyrSDK.configure(apiKey: "", workspaceId: "ws", debug: false,
                                           enableAutoEvents: true, enableAttribution: false)
        }
        XCTAssertFalse(DatalyrSDK.shared.isInitialized)
    }

    func testConfigureBuildsTheSameConfigAsBothOldOverloads() {
        let basic = DatalyrSDK.configureConfig(apiKey: "dk_test", workspaceId: "ws", debug: true)
        XCTAssertEqual(basic.apiKey, "dk_test")
        XCTAssertEqual(basic.workspaceId, "ws")
        XCTAssertTrue(basic.debug)
        XCTAssertTrue(basic.enableAutoEvents)
        XCTAssertTrue(basic.enableAttribution)
        XCTAssertNil(basic.autoEventConfig, "nil reads as AutoEventConfig(), the defaults both overloads used")

        let full = DatalyrSDK.configureConfig(apiKey: "dk_test", enableAutoEvents: false, enableAttribution: false)
        XCTAssertFalse(full.enableAutoEvents)
        XCTAssertFalse(full.enableAttribution)
        XCTAssertFalse(full.debug)
        XCTAssertEqual(full.workspaceId, "")
        XCTAssertTrue(full.useServerTracking)
    }

    // MARK: - W14: trackPurchase

    private final class Events {
        private let lock = NSLock()
        private var _all: [(String, EventData?)] = []
        func append(_ e: (String, EventData?)) { lock.withLock { _all.append(e) } }
        var all: [(String, EventData?)] { lock.withLock { _all } }
    }

    /// An isolated, initialized instance with no event queue and no network.
    private func isolatedSDK(_ config: DatalyrConfig, events: Events) async -> DatalyrSDK {
        let manager = AttributionManager()
        await manager.initialize()
        let sdk = DatalyrSDK()
        sdk.trackObserverForTesting = { name, data in events.append((name, data)) }
        sdk.configureForDeferredLookupTesting(
            config: config,
            attributionManager: manager,
            platformIntegrationManager: PlatformIntegrationManager()
        )
        return sdk
    }

    func testTrackPurchaseSendsAPurchaseEvent() async throws {
        let events = Events()
        let sdk = await isolatedSDK(DatalyrConfig(apiKey: "dk_test"), events: events)

        await sdk.trackPurchase(value: 19.99, currency: "EUR", productId: "sku_1")
        await sdk.trackPurchase(value: 5)

        let purchases = events.all.filter { $0.0 == "purchase" }.map { $0.1 ?? [:] }
        XCTAssertEqual(purchases.count, 2, "\(events.all.map(\.0))")
        XCTAssertEqual(purchases[0]["revenue"] as? Double, 19.99)
        XCTAssertEqual(purchases[0]["currency"] as? String, "EUR")
        XCTAssertEqual(purchases[0]["product_id"] as? String, "sku_1")
        XCTAssertEqual(purchases[1]["revenue"] as? Double, 5)
        XCTAssertEqual(purchases[1]["currency"] as? String, "USD", "currency defaults to USD")
        XCTAssertNil(purchases[1]["product_id"])
    }

    // MARK: - W14: global helpers and static shortcuts compile and run

    /// The shared instance is never initialized in tests, so these calls buffer or no-op.
    /// The point is that every public helper keeps its signature and can be called.
    func testGlobalHelpersCompileAndCall() async {
        await datalyrTrack("pass1_helper_probe")
        await datalyrTrack("pass1_helper_probe", properties: ["k": "v"])
        await datalyrScreen("Home")
        await datalyrScreen("Home", properties: ["tab": "feed"])
        await datalyrIdentify("user_probe")
        await datalyrIdentify("user_probe", properties: ["plan": "pro"], provisional: true)
        await datalyrAlias("user_probe_2")
        await datalyrAlias("user_probe_2", previousId: "user_probe")
        await datalyrFlush()
        await datalyrReset()
        _ = datalyrGetAnonymousId()
        await datalyrTrackWithSKAdNetwork("pass1_helper_probe")
        await datalyrTrackWithSKAdNetwork("pass1_helper_probe", properties: ["value": 1])
        await datalyrTrackPurchase(value: 1)
        await datalyrTrackPurchase(value: 1, currency: "EUR", productId: "sku")
        await datalyrTrackSubscription(value: 1)
        await datalyrTrackSubscription(value: 1, currency: "EUR", plan: "monthly")
        XCTAssertNil(datalyrGetConversionValue(for: "purchase"), "no encoder without initialize")
        XCTAssertNil(datalyrGetConversionValue(for: "purchase", properties: ["value": 1]))

        await DatalyrSDK.trackPurchase(value: 1)
        await DatalyrSDK.trackPurchase(value: 1, currency: "EUR", productId: "sku")
        await DatalyrSDK.trackSubscription(value: 1, currency: "EUR", plan: "monthly")
        XCTAssertFalse(DatalyrSDK.shared.isInitialized)
    }
}
