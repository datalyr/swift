import XCTest
@testable import DatalyrSDK

/// Stubs POST /attribution/deferred-lookup for URLSession.shared (the session the SDK uses).
final class DeferredLookupStub: URLProtocol {
    private static let lock = NSLock()
    private static var _bodies: [[String: Any]] = []
    private static var _responses: [(status: Int, body: [String: Any])] = []

    static var bodies: [[String: Any]] { lock.withLock { _bodies } }
    static func enqueue(status: Int = 200, _ body: [String: Any]) {
        lock.withLock { _responses.append((status, body)) }
    }
    static func reset() {
        lock.withLock { _bodies = []; _responses = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/attribution/deferred-lookup"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let response: (status: Int, body: [String: Any]) = Self.lock.withLock {
            Self._bodies.append(body)
            return Self._responses.isEmpty
                ? (200, ["found": false, "reason": "no_web_traffic"])
                : Self._responses.removeFirst()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: response.body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Drives the REAL SDK wiring — DatalyrSDK.runDeferredLookupIfEligible →
/// fetchDeferredWebAttribution → URLSession.shared — on an isolated instance (no event queue),
/// with the ATT status injected through PlatformIntegrationManager.attStatusProvider.
final class DeferredLookupWiringTests: XCTestCase {

    private final class Box<T> {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private var att = Box<UInt>(0)
    private var events = Box<[(String, EventData?)]>([])

    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(DeferredLookupStub.self)
        DeferredLookupStub.reset()
        att = Box(0)
        events = Box([])
        await ATTDeferredLookupTests.clearLookupStorage()
        await DatalyrStorage.shared.removeValue(StorageKeys.firstLaunchTime) // fresh install
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(DeferredLookupStub.self)
        DeferredLookupStub.reset()
        await ATTDeferredLookupTests.clearLookupStorage()
        try await super.tearDown()
    }

    /// A new "launch": fresh SDK + managers over the same persisted storage.
    private func launch() async -> DatalyrSDK {
        let manager = AttributionManager()
        await manager.initialize()
        let platform = PlatformIntegrationManager()
        let att = self.att
        platform.attStatusProvider = { att.value }
        let sdk = DatalyrSDK()
        let events = self.events
        sdk.trackObserverForTesting = { name, data in events.value.append((name, data)) }
        sdk.configureForDeferredLookupTesting(
            config: DatalyrConfig(apiKey: "dk_test"),
            attributionManager: manager,
            platformIntegrationManager: platform
        )
        return sdk
    }

    private var sentStatuses: [Int] { DeferredLookupStub.bodies.map { $0["att_status"] as? Int ?? -1 } }
    private func attempts() async -> Double { await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupAttempts) ?? 0 }
    private func resolved() async -> Bool { await DatalyrStorage.shared.getBool(StorageKeys.deferredLookupResolved) ?? false }
    private var attMisses: Int {
        events.value.filter { $0.0 == "$attribution_match" && ($0.1?["reason"] as? String) == "att_not_authorized" }.count
    }

    private func waitForRequests(_ n: Int, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while DeferredLookupStub.bodies.count < n && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - att_status is read live and sent

    func testSentBodyCarriesLiveATTStatus() async {
        att.value = 0
        let sdk = await launch()          // init-time cache sees 0
        att.value = 2                     // user denied after init
        DeferredLookupStub.enqueue(["found": false, "reason": "not_enabled"])
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(sentStatuses, [2], "att_status must be the live status at request time")
        XCTAssertEqual(DeferredLookupStub.bodies.first?["platform"] as? String, "ios")
    }

    // MARK: - att_not_authorized → refund, wait, re-run on grant

    func testRefusalKeepsAttemptAndForegroundGrantReruns() async {
        att.value = 0
        let sdk = await launch()
        DeferredLookupStub.enqueue(["found": false, "reason": "att_not_authorized"])
        await sdk.runDeferredLookupIfEligible()

        XCTAssertEqual(sentStatuses, [0])
        let afterRefusal = await attempts()
        XCTAssertEqual(afterRefusal, 0, "att_not_authorized must not consume an attempt")
        let isResolved = await resolved()
        XCTAssertFalse(isResolved, "att_not_authorized must not resolve the lookup")
        XCTAssertEqual(attMisses, 1)

        // App called ATTrackingManager itself; user allowed; app becomes active.
        att.value = 3
        DeferredLookupStub.enqueue(["found": false, "reason": "no_web_traffic"])
        let task = sdk.refreshATTOnForeground()
        XCTAssertNotNil(task, "0 → 3 must start the re-run")
        await task?.value
        XCTAssertEqual(sentStatuses, [0, 3], "re-run after grant carries att_status 3")
        let afterAnswer = await attempts()
        XCTAssertEqual(afterAnswer, 1)
        let nowResolved = await resolved()
        XCTAssertTrue(nowResolved)
    }

    func testUpdateTrackingAuthorizationGrantReruns() async {
        att.value = 0
        let sdk = await launch()
        DeferredLookupStub.enqueue(["found": false, "reason": "att_not_authorized"])
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(sentStatuses, [0])

        att.value = 3
        await sdk.updateTrackingAuthorization(status: 3)
        await waitForRequests(2)
        XCTAssertEqual(sentStatuses, [0, 3])
    }

    /// (a) A refused install is asked again on each later launch (the workspace may have
    /// turned on matching without ATT) — no attempt spent, no duplicate miss event.
    func testRefusedInstallIsAskedAgainNextLaunchWithoutSpendingAttempts() async {
        att.value = 2
        var sdk = await launch()
        DeferredLookupStub.enqueue(["found": false, "reason": "att_not_authorized"])
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(attMisses, 1)

        for _ in 0..<4 {
            DeferredLookupStub.enqueue(["found": false, "reason": "att_not_authorized"])
            sdk = await launch()
            await sdk.runDeferredLookupIfEligible()
        }
        XCTAssertEqual(sentStatuses, [2, 2, 2, 2, 2], "asked on every launch inside the window")
        let spent = await attempts()
        XCTAssertEqual(spent, 0, "refused requests never spend attempts")
        let isResolved = await resolved()
        XCTAssertFalse(isResolved)
        XCTAssertEqual(attMisses, 1, "miss reported once per install per ATT status")

        // A different status is a new report.
        att.value = 0
        DeferredLookupStub.enqueue(["found": false, "reason": "att_not_authorized"])
        sdk = await launch()
        await sdk.runDeferredLookupIfEligible()
        XCTAssertEqual(attMisses, 2)
    }

    /// (b) The customer turns on matching without ATT: the refused install's next lookup gets
    /// the real answer, and the refused status is cleared (no grant re-run afterwards).
    func testRefusedInstallGetsRealAnswerOnceServerAllowsIt() async {
        for answer: [String: Any] in [
            ["found": true, "attribution": ["visitor_id": "web_vis_1", "fbclid": "fb_1",
                                            "utm_source": "facebook"]],
            ["found": false, "reason": "no_candidates"],
        ] {
            await ATTDeferredLookupTests.clearLookupStorage()
            DeferredLookupStub.reset()
            events.value = []
            att.value = 2

            var sdk = await launch()
            DeferredLookupStub.enqueue(["found": false, "reason": "att_not_authorized"])
            await sdk.runDeferredLookupIfEligible()
            let refusedBefore = await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupRefusedATTStatus)
            XCTAssertEqual(refusedBefore, 2)

            // Next launch, server switch now on.
            DeferredLookupStub.enqueue(answer)
            sdk = await launch()
            await sdk.runDeferredLookupIfEligible()
            XCTAssertEqual(DeferredLookupStub.bodies.count, 2)
            let refusedAfter = await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupRefusedATTStatus)
            XCTAssertNil(refusedAfter, "a real answer clears the refusal")
            let spent = await attempts()
            XCTAssertEqual(spent, 1, "the answered request spends its attempt")

            if (answer["found"] as? Bool) == true {
                XCTAssertTrue(events.value.contains { $0.0 == "$web_attribution_matched" })
                let isResolved = await resolved()
                XCTAssertTrue(isResolved)
            } else {
                XCTAssertTrue(events.value.contains {
                    $0.0 == "$attribution_match" && ($0.1?["reason"] as? String) == "no_candidates"
                })
            }

            // Granting later does not re-send (no refusal on record any more).
            att.value = 3
            await sdk.refreshATTOnForeground()?.value
            XCTAssertEqual(DeferredLookupStub.bodies.count, 2)
        }
    }

    // MARK: - Allowing workspaces behave like 2.1.17

    func testGrantDoesNotResendAFreshNoCandidates() async {
        att.value = 0
        let sdk = await launch()
        DeferredLookupStub.enqueue(["found": false, "reason": "no_candidates"]) // fresh install → kept open
        await sdk.runDeferredLookupIfEligible()
        let open = await resolved()
        XCTAssertFalse(open)

        att.value = 3
        await sdk.refreshATTOnForeground()?.value
        await sdk.updateTrackingAuthorization(status: 3)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(DeferredLookupStub.bodies.count, 1, "no grant re-run without an att_not_authorized answer")
    }

    func testGrantDoesNotResendAfterServerError() async {
        att.value = 0
        let sdk = await launch()
        DeferredLookupStub.enqueue(status: 503, ["error": "unavailable"])
        await sdk.runDeferredLookupIfEligible()

        att.value = 3
        await sdk.refreshATTOnForeground()?.value
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(DeferredLookupStub.bodies.count, 1)
        let spent = await attempts()
        XCTAssertEqual(spent, 1, "a 503 still spends the attempt")
    }

    /// A refusal followed by a server error keeps waiting for the grant.
    func testRefusalSurvivesALaterServerError() async {
        att.value = 0
        let sdk = await launch()
        DeferredLookupStub.enqueue(["found": false, "reason": "att_not_authorized"])
        await sdk.runDeferredLookupIfEligible()
        att.value = 3
        DeferredLookupStub.enqueue(status: 503, ["error": "unavailable"])
        await sdk.refreshATTOnForeground()?.value
        XCTAssertEqual(sentStatuses, [0, 3])
    }

    // MARK: - Declined although authorized

    func testRefusalAtStatus3IsNotRefunded() async {
        att.value = 3
        let sdk = await launch()
        DeferredLookupStub.enqueue(["found": false, "reason": "att_not_authorized"])
        await sdk.runDeferredLookupIfEligible()
        let spent = await attempts()
        XCTAssertEqual(spent, 1, "only a refusal at a non-authorized status is refunded")
        let refused = await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupRefusedATTStatus)
        XCTAssertNil(refused)
    }
}
