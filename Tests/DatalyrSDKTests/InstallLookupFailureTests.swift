import XCTest
@testable import DatalyrSDK

/// FX-052 (SDK part) and INST-01 (SDK slice): the install lookup
/// (POST /attribution/deferred-lookup) sends the SDK's anonymous_id, reports every failed
/// lookup with an error class and the elapsed milliseconds, and tries a timed-out lookup
/// once more in the first hour after install.
///
/// Drives the real wiring (runDeferredLookupIfEligible → fetchDeferredWebAttribution →
/// URLSession.shared) through DeferredLookupStub.
final class InstallLookupFailureTests: XCTestCase {

    private final class Box<T> {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private var events = Box<[(String, EventData?)]>([])

    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(DeferredLookupStub.self)
        DeferredLookupStub.reset()
        events = Box([])
        await ATTDeferredLookupTests.clearLookupStorage()
        await DatalyrStorage.shared.removeValue(StorageKeys.firstLaunchTime) // fresh install
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(DeferredLookupStub.self)
        DeferredLookupStub.reset()
        await ATTDeferredLookupTests.clearLookupStorage()
        await DatalyrStorage.shared.removeValue(StorageKeys.firstLaunchTime)
        try await super.tearDown()
    }

    private func launch() async -> DatalyrSDK {
        let manager = AttributionManager()
        await manager.initialize()
        let platform = PlatformIntegrationManager()
        platform.attStatusProvider = { 3 }
        let sdk = DatalyrSDK()
        let events = self.events
        sdk.trackObserverForTesting = { name, data in events.value.append((name, data)) }
        sdk.configureForDeferredLookupTesting(
            config: DatalyrConfig(apiKey: "dk_test"),
            attributionManager: manager,
            platformIntegrationManager: platform
        )
        await sdk.loadIdentityForTesting()
        return sdk
    }

    private var failures: [EventData] {
        events.value.compactMap { name, data in
            name == "$attribution_match" && (data?["reason"] as? String) == "request_failed" ? data : nil
        }
    }
    private func resolved() async -> Bool { await DatalyrStorage.shared.getBool(StorageKeys.deferredLookupResolved) ?? false }
    private func attempts() async -> Double { await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupAttempts) ?? 0 }

    /// The failure event carries only these keys: no URL, no new identifier.
    private static let failureKeys: Set<String> = [
        "provider", "match_method", "matched", "reason", "error_class", "error_code", "http_status", "elapsed_ms", "timeout_retry",
    ]

    private func assertFailure(_ data: EventData?, errorClass: String, httpStatus: Int? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let data = data else { return XCTFail("no request_failed event", file: file, line: line) }
        XCTAssertEqual(data["error_class"] as? String, errorClass, file: file, line: line)
        let elapsed = data["elapsed_ms"] as? Int
        XCTAssertNotNil(elapsed, "elapsed_ms is a whole number of milliseconds", file: file, line: line)
        XCTAssertGreaterThanOrEqual(elapsed ?? -1, 0, file: file, line: line)
        XCTAssertEqual(data["http_status"] as? Int, httpStatus, file: file, line: line)
        XCTAssertTrue(Set(data.keys).isSubset(of: Self.failureKeys),
                      "unexpected keys: \(Set(data.keys).subtracting(Self.failureKeys))", file: file, line: line)
        for value in data.values {
            if let s = value as? String { XCTAssertFalse(s.contains("://"), "no URL in the event", file: file, line: line) }
        }
    }

    // MARK: - anonymous_id in the request body (FX-052)

    func testRequestBodyCarriesAnonymousIdWhenGiven() {
        let base: (String?) -> [String: Any] = { id in
            DeferredLookup.requestBody(osVersion: "18.1", deviceModel: "iPhone16,1", timezone: "UTC",
                                       language: "en-US", attStatus: 3, anonymousId: id)
        }
        XCTAssertEqual(base("anon_TEST-0001")["anonymous_id"] as? String, "anon_TEST-0001")
        XCTAssertNil(base(nil)["anonymous_id"], "absent when the SDK has no id")
        XCTAssertNil(base("")["anonymous_id"], "absent when empty")
        XCTAssertNil(base(String(repeating: "a", count: 129))["anonymous_id"],
                     "over 128 characters the server ignores it, so it is not sent")
    }

    func testLookupSendsTheSDKsAnonymousId() async {
        let sdk = await launch()
        let anonymousId = sdk.getAnonymousId()
        XCTAssertFalse(anonymousId.isEmpty)
        DeferredLookupStub.enqueue(["found": false, "reason": "no_web_traffic"])
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(DeferredLookupStub.bodies.count, 1)
        XCTAssertEqual(DeferredLookupStub.bodies.first?["anonymous_id"] as? String, anonymousId)
    }

    // MARK: - failure event: error class + elapsed time (INST-01)

    func testTimeoutIsReportedAsTimeoutWithElapsedTime() async {
        let sdk = await launch()
        DeferredLookupStub.enqueueFailure(.timedOut)
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(DeferredLookupStub.bodies.count, 1, "the lookup itself never retries in line")
        XCTAssertEqual(failures.count, 1)
        assertFailure(failures.first, errorClass: "timeout")
        XCTAssertEqual(failures.first?["error_code"] as? Int, URLError.Code.timedOut.rawValue)
        let isResolved = await resolved()
        XCTAssertFalse(isResolved, "a timeout stays eligible for a later launch")
    }

    func testNonHTTPResponseIsReportedAsNetwork() async {
        let sdk = await launch()
        DeferredLookupStub.enqueueNonHTTP()
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(failures.count, 1, "a non-HTTP answer used to send no event")
        assertFailure(failures.first, errorClass: "network")
        let isResolved = await resolved()
        XCTAssertFalse(isResolved)
    }

    func testTransportErrorIsReportedAsNetwork() async {
        let sdk = await launch()
        DeferredLookupStub.enqueueFailure(.notConnectedToInternet)
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(failures.count, 1)
        assertFailure(failures.first, errorClass: "network")
        XCTAssertEqual(failures.first?["error_code"] as? Int, URLError.Code.notConnectedToInternet.rawValue)
    }

    func testServerErrorIsReportedWithItsStatusClass() async {
        let sdk = await launch()
        DeferredLookupStub.enqueue(status: 503, ["error": "Temporarily unavailable"])
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(failures.count, 1, "a 5xx used to produce no event at all")
        assertFailure(failures.first, errorClass: "http_5xx", httpStatus: 503)
        let isResolved = await resolved()
        XCTAssertFalse(isResolved, "unchanged: a 5xx stays eligible")
    }

    func testClientErrorIsReportedWithItsStatusClass() async {
        let sdk = await launch()
        DeferredLookupStub.enqueue(status: 410, ["error": "Deferred IP attribution is disabled"])
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(failures.count, 1)
        assertFailure(failures.first, errorClass: "http_4xx", httpStatus: 410)
        let isResolved = await resolved()
        XCTAssertTrue(isResolved, "unchanged: a 4xx other than 408/429 is final for this install")
    }

    func testUnreadableAnswerIsReportedAsDecode() async {
        let sdk = await launch()
        DeferredLookupStub.enqueueUnparseable()
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(failures.count, 1)
        assertFailure(failures.first, errorClass: "decode")
        let isResolved = await resolved()
        XCTAssertFalse(isResolved, "unchanged: an unreadable answer stays eligible")
    }

    func testAnswersThatAreNotFailuresCarryNoErrorClass() async {
        let sdk = await launch()
        DeferredLookupStub.enqueue(["found": false, "reason": "no_web_traffic", "window_minutes": 180])
        await sdk.runDeferredLookupIfEligible()
        let outcome = events.value.first { $0.0 == "$attribution_match" }?.1
        XCTAssertEqual(outcome?["reason"] as? String, "no_web_traffic")
        XCTAssertNil(outcome?["error_class"])
        XCTAssertNil(outcome?["elapsed_ms"])
    }

    // MARK: - one retry on a timeout, first hour after install, after app_install

    func testTimeoutInFirstHourIsRetriedOnceAndTheAnswerIsUsed() async {
        let sdk = await launch()
        DeferredLookupStub.enqueueFailure(.timedOut)
        DeferredLookupStub.enqueue(["found": true, "attribution": [
            "visitor_id": "web_vis_1", "fbclid": "fb_test_1", "utm_source": "facebook",
        ]])
        await sdk.runDeferredLookupIfEligible()
        await sdk.startOwedTimeoutRetry()?.value

        let bodies = DeferredLookupStub.bodies
        XCTAssertEqual(bodies.count, 2, "exactly one retry")
        XCTAssertEqual(bodies.map { $0["anonymous_id"] as? String }, [sdk.getAnonymousId(), sdk.getAnonymousId()],
                       "the retry carries the same anonymous_id, so the server's click claim sees the same device")
        XCTAssertEqual(bodies[0] as NSDictionary, bodies[1] as NSDictionary, "the retry sends the same body")
        XCTAssertTrue(events.value.contains { $0.0 == "$web_attribution_matched" })
        XCTAssertEqual(failures.count, 1, "the first attempt's timeout is still reported")
        let matched = events.value.first { $0.0 == "$attribution_match" && ($0.1?["matched"] as? Bool) == true }?.1
        XCTAssertEqual(matched?["timeout_retry"] as? Bool, true, "the outcome says a retry was needed")
        let spent = await attempts()
        XCTAssertEqual(spent, 1, "the retry is part of the same attempt")
        let isResolved = await resolved()
        XCTAssertTrue(isResolved)
        XCTAssertNil(sdk.startOwedTimeoutRetry(), "only one retry")
    }

    func testRetryThatTimesOutToo() async {
        let sdk = await launch()
        DeferredLookupStub.enqueueFailure(.timedOut)
        DeferredLookupStub.enqueueFailure(.timedOut)
        await sdk.runDeferredLookupIfEligible()
        await sdk.startOwedTimeoutRetry()?.value
        XCTAssertEqual(DeferredLookupStub.bodies.count, 2)
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(failures.last?["timeout_retry"] as? Bool, true)
        XCTAssertNil(sdk.startOwedTimeoutRetry(), "a retry's timeout owes nothing more")
        let spent = await attempts()
        XCTAssertEqual(spent, 1)
    }

    /// Review fix: the retry must not lengthen the launch. initialize() runs
    /// runLaunchLookupAndInstall(); with the first lookup timing out, it returns after one
    /// lookup and app_install, and the retry happens afterwards in the background.
    func testLaunchDoesNotWaitForTheTimeoutRetry() async {
        await DatalyrStorage.shared.removeValue("datalyr_app_install_tracked")
        defer { Task { await DatalyrStorage.shared.removeValue("datalyr_app_install_tracked") } }
        let sdk = await launch()
        DeferredLookupStub.enqueueFailure(.timedOut)
        DeferredLookupStub.enqueue(["found": true, "attribution": ["visitor_id": "web_vis_2", "fbclid": "fb_test_2"]])
        DeferredLookupStub.setDelay(forRequest: 1, 1.5) // the retry's answer is slow

        let started = Date()
        let retry = await sdk.runLaunchLookupAndInstall()
        let launchSeconds = Date().timeIntervalSince(started)

        XCTAssertLessThan(launchSeconds, 1.0, "the launch did not wait for the retry")
        XCTAssertTrue(events.value.contains { $0.0 == "app_install" }, "app_install is sent before the retry")
        XCTAssertFalse(events.value.contains { $0.0 == "$web_attribution_matched" })
        XCTAssertNotNil(retry)

        await retry?.value
        let names = events.value.map { $0.0 }
        guard let install = names.firstIndex(of: "app_install"),
              let match = names.firstIndex(of: "$web_attribution_matched") else {
            return XCTFail("expected app_install then the match")
        }
        XCTAssertLessThan(install, match, "the retry's match arrives after app_install")
    }

    func testOtherTransportErrorsAreNotRetriedInTheSameRun() async {
        let sdk = await launch()
        DeferredLookupStub.enqueueFailure(.notConnectedToInternet)
        DeferredLookupStub.enqueue(["found": false, "reason": "no_web_traffic"]) // must not be used
        await sdk.runDeferredLookupIfEligible()
        XCTAssertNil(sdk.startOwedTimeoutRetry(), "no retry owed")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(DeferredLookupStub.bodies.count, 1, "no second request")
        XCTAssertFalse(events.value.contains { ($0.1?["reason"] as? String) == "no_web_traffic" })
    }

    func testTimeoutAfterTheFirstHourIsNotRetriedInTheSameRun() async {
        let twoHoursAgo = DateFormatter.iso8601.string(from: Date().addingTimeInterval(-2 * 3600))
        await DatalyrStorage.shared.setString(StorageKeys.firstLaunchTime, value: twoHoursAgo)
        let sdk = await launch()
        DeferredLookupStub.enqueueFailure(.timedOut)
        DeferredLookupStub.enqueue(["found": false, "reason": "no_web_traffic"]) // must not be used
        await sdk.runDeferredLookupIfEligible()
        XCTAssertNil(sdk.startOwedTimeoutRetry(), "no retry after the first hour")
        XCTAssertEqual(failures.count, 1)
        assertFailure(failures.first, errorClass: "timeout")
        XCTAssertFalse(events.value.contains { ($0.1?["reason"] as? String) == "no_web_traffic" })
    }
}
