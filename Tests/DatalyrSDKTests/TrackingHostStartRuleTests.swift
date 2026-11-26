import XCTest
@testable import DatalyrSDK

/// Answers POST /track on the normal test host and on tracking.datalyr.com, and records every
/// request (host, event id, body). Installed through DatalyrHTTPClient.protocolClassesForTesting,
/// so nothing reaches the network.
final class RouteStub: URLProtocol {
    struct Request {
        let host: String
        let eventId: String
        let eventName: String
        let anonymousId: String?
        let properties: [String: Any]
        let rawBody: String
    }

    private static let lock = NSLock()
    private static var _requests: [Request] = []
    private static var _handler: (String, String) -> IngestStub.Answer = { _, _ in .status(200) }

    static var requests: [Request] { lock.withLock { _requests } }
    /// (host, event name) -> answer.
    static var handler: (String, String) -> IngestStub.Answer {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    static func reset() { lock.withLock { _requests = []; _handler = { _, _ in .status(200) } } }

    static let normalHost = "ingest-route.test"
    static let trackingHost = "tracking.datalyr.com"
    static func on(_ host: String) -> [Request] { requests.filter { $0.host == host } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == normalHost || host == trackingHost
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
        let host = request.url?.host ?? ""
        let name = body["event"] as? String ?? ""
        let recorded = Request(host: host, eventId: body["eventId"] as? String ?? "", eventName: name,
                               anonymousId: body["anonymousId"] as? String,
                               properties: body["properties"] as? [String: Any] ?? [:],
                               rawBody: String(data: data, encoding: .utf8) ?? "")
        let handler: (String, String) -> IngestStub.Answer = Self.lock.withLock {
            Self._requests.append(recorded)
            return Self._handler
        }
        switch handler(host, name) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let code, let headers):
            let http = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"].merging(headers) { $1 })!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// 2.3.1: iOS opens the tracking domain only to app processes started after tracking was
/// allowed (proved on an iPhone). An event goes to tracking.datalyr.com only when tracking was
/// authorized when the process started, is authorized at send time, and the event carries a
/// real IDFA. Otherwise it goes to the normal host without the IDFA. A failed tracking-host
/// request falls back to the normal host in the same send.
final class TrackingHostStartRuleTests: XCTestCase {

    static let idfa = "ABCDEF01-2345-6789-ABCD-EF0123456789"
    static let normalEndpoint = "https://\(RouteStub.normalHost)/track"

    private final class Box<T> {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private static let storageKeys = [
        StorageKeys.eventQueue, StorageKeys.deadLetterQueue, "datalyr_app_install_tracked", StorageKeys.installClass,
        StorageKeys.existingUserInstall, StorageKeys.firstLaunchTime, StorageKeys.attIdWithheld,
    ]
    private var savedSignals: (() async -> InstallSignals)!

    override func setUp() async throws {
        try await super.setUp()
        RouteStub.reset()
        DatalyrHTTPClient.protocolClassesForTesting = [RouteStub.self]
        savedSignals = DatalyrSDK.installSignalsProvider
        let now = Date()
        DatalyrSDK.installSignalsProvider = {
            InstallSignals(ranBefore: false, earliestEvidence: nil, processStart: now,
                           bundleNewerThanContainer: false, containerCreatedAt: now,
                           store: nil, currentBuild: "1", now: now)
        }
        for key in Self.storageKeys { await DatalyrStorage.shared.removeValue(key) }
    }

    override func tearDown() async throws {
        DatalyrHTTPClient.protocolClassesForTesting = nil
        DatalyrSDK.installSignalsProvider = savedSignals
        TrackingStatusAtStart.overrideForTesting = nil
        PlatformIntegrationManager.liveStatusForTesting = nil
        PlatformIntegrationManager.idfaForTesting = nil
        RouteStub.reset()
        for key in Self.storageKeys { await DatalyrStorage.shared.removeValue(key) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func client(start: UInt?, now: UInt) -> DatalyrHTTPClient {
        let client = DatalyrHTTPClient(endpoint: Self.normalEndpoint,
                                       config: HTTPClientConfig(apiKey: "dk_test_route_key"))
        client.attStatusProvider = { now }
        client.attStatusAtProcessStartProvider = { start }
        return client
    }

    private enum IdCase: CaseIterable { case real, zero, empty, none }
    private enum Mode: CaseIterable { case fresh, retry, stored }

    /// An event as the SDK builds it: with an id field (authorized when built) or without one.
    private func eventData(_ id: IdCase) -> [String: Any] {
        let value: String
        switch id {
        case .real: value = Self.idfa
        case .zero: value = DatalyrHTTPClient.zeroIDFA
        case .empty: value = ""
        case .none:
            return ["att_status": UInt(0), "advertiser_tracking_enabled": false,
                    "advertiser_data": ["att_status": UInt(0), "tracking_authorized": false] as [String: Any],
                    "plan": "pro"]
        }
        return ["idfa": value, "att_status": UInt(3), "advertiser_tracking_enabled": true, "alart": "applovin_user_1",
                "advertiser_data": ["idfa": value, "att_status": UInt(3), "tracking_authorized": true] as [String: Any],
                "plan": "pro"]
    }

    private func payload(_ id: IdCase, eventId: String = UUID().uuidString, name: String = "route_test") -> EventPayload {
        EventPayload(workspaceId: "ws_route", visitorId: "vis_route", anonymousId: "anon_route",
                     sessionId: "sess_route", eventId: eventId, eventName: name, eventData: eventData(id))
    }

    private func reloaded(_ payload: EventPayload) throws -> EventPayload {
        // The queue is stored with JSONEncoder and reloaded with JSONDecoder (DatalyrStorage).
        let data = try JSONEncoder().encode([QueuedEvent(payload: payload, timestamp: 1_700_000_000)])
        return try XCTUnwrap(try JSONDecoder().decode([QueuedEvent].self, from: data).first?.payload)
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: - Process-start status

    func testProcessStartStatusIsReadWhenTheSDKIsLoaded() {
        // The loader's constructor runs before main(), so before any test or SDK call.
        let raw = TrackingStatusAtStart.rawCapturedAtLoad
        XCTAssertNotEqual(raw, -1, "the ATT status was not read when the SDK was loaded")
        XCTAssertTrue((0...3).contains(raw) || raw == -2, "unexpected value \(raw)")
        if (0...3).contains(raw) { XCTAssertEqual(TrackingStatusAtStart.value(), UInt(raw)) }
    }

    // MARK: - The full table

    /// allowed at start (yes / no / unreadable) x now (authorized / denied / restricted / not
    /// determined) x id (real / all-zero / empty / none) x attempt (fresh / retry / stored).
    func testRoutingTable() async throws {
        let starts: [UInt?] = [3, 0, nil]
        let nows: [UInt] = [3, 2, 1, 0]
        for start in starts {
            for now in nows {
                for id in IdCase.allCases {
                    for mode in Mode.allCases {
                        try await checkRow(start: start, now: now, id: id, mode: mode)
                    }
                }
            }
        }
    }

    private func checkRow(start: UInt?, now: UInt, id: IdCase, mode: Mode) async throws {
        let row = "start \(start.map { "\($0)" } ?? "unreadable"), now \(now), id \(id), \(mode)"
        RouteStub.reset()
        let client = self.client(start: start, now: now)
        let eventId = "evt_\(UUID().uuidString)"
        var sent = payload(id, eventId: eventId)
        let expectTracking = start == 3 && now == 3 && id == .real

        switch mode {
        case .fresh:
            break
        case .stored:
            sent = try reloaded(sent)
        case .retry:
            // First attempt answered 500 with Retry-After (kept and retried, no fallback).
            let answered = Box(false)
            RouteStub.handler = { _, _ in
                if answered.value { return .status(200) }
                answered.value = true
                return .status(500, headers: ["Retry-After": "1"])
            }
            let first = await client.sendEvent(sent)
            XCTAssertFalse(first.success, row)
            XCTAssertEqual(RouteStub.requests.count, 1, "\(row): no fallback on a Retry-After answer")
        }

        let response = await client.sendEvent(sent)
        XCTAssertTrue(response.success, row)
        let requests = RouteStub.requests
        let last = try XCTUnwrap(requests.last, row)
        XCTAssertEqual(last.eventId, eventId, row)
        XCTAssertEqual(last.host, expectTracking ? RouteStub.trackingHost : RouteStub.normalHost, row)
        XCTAssertEqual(requests.filter { $0.host == RouteStub.trackingHost }.count,
                       expectTracking ? requests.count : 0, "\(row): no request to the tracking host first")
        let props = last.properties
        XCTAssertEqual(props["plan"] as? String, "pro", row)
        let advertiser = props["advertiser_data"] as? [String: Any]

        if expectTracking {
            XCTAssertEqual(props["idfa"] as? String, Self.idfa, row)
            XCTAssertEqual(props["alart"] as? String, "applovin_user_1", row)
            XCTAssertEqual(props["att_status"] as? Int, 3, row)
            XCTAssertEqual(props["advertiser_tracking_enabled"] as? Bool, true, row)
            XCTAssertEqual(advertiser?["idfa"] as? String, Self.idfa, row)
            return
        }
        XCTAssertFalse(last.rawBody.contains(Self.idfa), "\(row): IDFA in a normal-host body")
        XCTAssertNil(props["idfa"], row)
        XCTAssertNil(props["alart"], row)
        XCTAssertNil(advertiser?["idfa"], row)
        if now != 3 {
            // Not authorized now: the permission fields show the status at send time.
            XCTAssertEqual(props["att_status"] as? Int, Int(now), row)
            XCTAssertEqual(props["advertiser_tracking_enabled"] as? Bool, false, row)
            XCTAssertEqual(advertiser?["att_status"] as? Int, Int(now), row)
            XCTAssertEqual(advertiser?["tracking_authorized"] as? Bool, false, row)
        } else if id == .none {
            // Authorized now, nothing tracking-only on the event: the body is unchanged.
            let expected = client.transformForServerAPI(sent)["properties"] as? [String: Any] ?? [:]
            XCTAssertEqual(NSDictionary(dictionary: props), NSDictionary(dictionary: expected), "\(row): body changed")
        } else {
            // Authorized now (allowed during this launch): only the id is removed.
            XCTAssertEqual(props["att_status"] as? Int, 3, row)
            XCTAssertEqual(props["advertiser_tracking_enabled"] as? Bool, true, row)
            XCTAssertEqual(advertiser?["att_status"] as? Int, 3, row)
            XCTAssertEqual(advertiser?["tracking_authorized"] as? Bool, true, row)
        }
    }

    func testStatusIsReadAgainOnEveryAttempt() async {
        // Built while authorized; the user turns tracking off, then on in Settings (iOS
        // relaunches the app on a change; the start status stays authorized in this test).
        let live = Box<UInt>(3)
        let client = self.client(start: 3, now: 3)
        client.attStatusProvider = { live.value }
        let event = payload(.real)
        _ = await client.sendEvent(event)
        live.value = 2
        _ = await client.sendEvent(event)
        live.value = 3
        _ = await client.sendEvent(event)
        XCTAssertEqual(RouteStub.requests.map(\.host), [RouteStub.trackingHost, RouteStub.normalHost, RouteStub.trackingHost])
        XCTAssertEqual(RouteStub.requests[1].properties["att_status"] as? Int, 2)
    }

    func testOwnEndpointWithoutServerTrackingIsUnchanged() {
        let client = DatalyrHTTPClient(endpoint: "https://legacy.example.invalid/track",
                                       config: HTTPClientConfig(apiKey: "dk_test_route_key", useServerTracking: false))
        client.attStatusProvider = { 3 }
        client.attStatusAtProcessStartProvider = { 3 }
        XCTAssertEqual(client.endpointFor(payload(.real)), "https://legacy.example.invalid/track")
    }

    // MARK: - Second line of defence: fallback and cool-down

    private func fallbackClient(clock: Box<TimeInterval>) -> DatalyrHTTPClient {
        let client = self.client(start: 3, now: 3)
        client.now = { clock.value }
        return client
    }

    private func checkFallback(_ trackingAnswer: IngestStub.Answer, _ label: String) async {
        RouteStub.reset()
        let clock = Box<TimeInterval>(1_800_000_000)
        let client = fallbackClient(clock: clock)
        RouteStub.handler = { host, _ in host == RouteStub.trackingHost ? trackingAnswer : .status(200) }

        let response = await client.sendEvent(payload(.real, eventId: "evt_fallback"))
        XCTAssertTrue(response.success, label)
        XCTAssertEqual(RouteStub.requests.map(\.host), [RouteStub.trackingHost, RouteStub.normalHost], label)
        XCTAssertEqual(RouteStub.requests.map(\.eventId), ["evt_fallback", "evt_fallback"], "\(label): same event id")
        let normal = RouteStub.requests[1]
        XCTAssertFalse(normal.rawBody.contains(Self.idfa), label)
        XCTAssertNil(normal.properties["alart"], label)
        XCTAssertEqual(normal.properties["att_status"] as? Int, 3, label)
        XCTAssertEqual(client.trackingHostAvoidedUntil, clock.value + 600, "\(label): 10-minute cool-down")

        // During the cool-down IDFA events go straight to the normal host.
        clock.value += 599
        _ = await client.sendEvent(payload(.real, eventId: "evt_cool"))
        XCTAssertEqual(RouteStub.requests.last?.host, RouteStub.normalHost, label)
        XCTAssertEqual(RouteStub.requests.count, 3, "\(label): no tracking-host request during the cool-down")
        XCTAssertEqual(client.trackingHostAvoidedUntil, 1_800_000_600, "\(label): not extended")

        // After it, the tracking host is tried again.
        clock.value += 2
        RouteStub.handler = { _, _ in .status(200) }
        _ = await client.sendEvent(payload(.real, eventId: "evt_after"))
        XCTAssertEqual(RouteStub.requests.last?.host, RouteStub.trackingHost, label)
        XCTAssertEqual(RouteStub.requests.count, 4, label)
    }

    func testFallbackOnNetworkFailure() async {
        await checkFallback(.failure(.notConnectedToInternet), "-1009 (blocked)")
        await checkFallback(.failure(.timedOut), "timeout")
    }

    func testFallbackOn503() async {
        await checkFallback(.status(503), "503")
    }

    func testFallbackOn403() async {
        await checkFallback(.status(403), "403")
    }

    func testNoFallbackOn429OrRetryAfter() async {
        for (answer, label) in [(IngestStub.Answer.status(429), "429"),
                                (.status(429, headers: ["Retry-After": "60"]), "429 + Retry-After"),
                                (.status(503, headers: ["Retry-After": "5"]), "503 + Retry-After")] {
            RouteStub.reset()
            let clock = Box<TimeInterval>(1_800_000_000)
            let client = fallbackClient(clock: clock)
            RouteStub.handler = { host, _ in host == RouteStub.trackingHost ? answer : .status(200) }
            let response = await client.sendEvent(payload(.real))
            XCTAssertFalse(response.success, label)
            XCTAssertEqual(RouteStub.requests.map(\.host), [RouteStub.trackingHost], "\(label): no fallback")
            XCTAssertEqual(client.trackingHostAvoidedUntil, 0, "\(label): no cool-down")
        }
    }

    func testBothHostsDownStartsNoCoolDown() async {
        let clock = Box<TimeInterval>(1_800_000_000)
        let client = fallbackClient(clock: clock)
        RouteStub.handler = { _, _ in .failure(.notConnectedToInternet) }
        let response = await client.sendEvent(payload(.real))
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.disposition, .retry(after: nil), "kept and retried by the normal rules")
        XCTAssertEqual(client.trackingHostAvoidedUntil, 0, "offline must not start the cool-down")
        RouteStub.handler = { _, _ in .status(200) }
        _ = await client.sendEvent(payload(.real))
        XCTAssertEqual(RouteStub.requests.last?.host, RouteStub.trackingHost)
    }

    // MARK: - Review A1: the tracking host alone keeps answering 429 / Retry-After

    func testRepeatedThrottleOnTheTrackingHostFallsBackAfterThreeInARowHonouringEachWait() async {
        for (answer, label) in [(IngestStub.Answer.status(429, headers: ["Retry-After": "1"]), "429 + Retry-After"),
                                (.status(429), "429"),
                                (.status(503, headers: ["Retry-After": "1"]), "503 + Retry-After")] {
            RouteStub.reset()
            await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
            let clock = Box<TimeInterval>(1_800_000_000)
            let client = fallbackClient(clock: clock)
            RouteStub.handler = { host, _ in host == RouteStub.trackingHost ? answer : .status(200) }
            let queue = await makeQueue(client)
            queue.now = { clock.value }
            await queue.enqueue(payload(.real, eventId: "evt_throttled"))

            // Three answers in a row from the tracking host; before each retry the queue waits
            // for the time the server asked for.
            for attempt in 1...3 {
                XCTAssertEqual(RouteStub.requests.count, attempt, "\(label): attempt \(attempt)")
                XCTAssertEqual(RouteStub.requests.last?.host, RouteStub.trackingHost, label)
                XCTAssertEqual(queue.getStats().queueSize, 1, label)
                let gate = queue.retryNotBefore
                XCTAssertGreaterThan(gate, clock.value, "\(label): the queue waits before retrying")
                await queue.flush()  // before the wait: nothing is sent
                XCTAssertEqual(RouteStub.requests.count, attempt, "\(label): no retry before the wait")
                clock.value = gate + 0.001
                if attempt < 3 {
                    XCTAssertEqual(client.trackingHostAvoidedUntil, 0, "\(label): no skip before 3 in a row")
                    await queue.flush()
                }
            }
            XCTAssertGreaterThan(client.trackingHostAvoidedUntil, clock.value, "\(label): 10-minute skip after 3 in a row")

            // The retry after the third wait goes to the normal host without the id.
            await queue.flush()
            XCTAssertEqual(queue.getStats().queueSize, 0, "\(label): the queue is not held")
            let last = RouteStub.requests.last
            XCTAssertEqual(last?.host, RouteStub.normalHost, label)
            XCTAssertEqual(last?.eventId, "evt_throttled", label)
            XCTAssertFalse(last?.rawBody.contains(Self.idfa) ?? true, label)
            await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
        }
    }

    func testThrottleCountIsPerEventAndInARow() async {
        let clock = Box<TimeInterval>(1_800_000_000)
        let client = fallbackClient(clock: clock)
        let answers = Box<[IngestStub.Answer]>([.status(429), .status(429), .status(200), .status(429), .status(429)])
        RouteStub.handler = { host, _ in
            guard host == RouteStub.trackingHost else { return .status(200) }
            var list = answers.value
            let next = list.isEmpty ? IngestStub.Answer.status(200) : list.removeFirst()
            answers.value = list
            return next
        }
        let first = payload(.real, eventId: "evt_a")
        _ = await client.sendEvent(first)
        _ = await client.sendEvent(first)
        let delivered = await client.sendEvent(first)
        XCTAssertTrue(delivered.success)
        let second = payload(.real, eventId: "evt_b")
        _ = await client.sendEvent(second)
        _ = await client.sendEvent(second)
        XCTAssertEqual(client.trackingHostAvoidedUntil, 0, "two in a row for each event: no skip")
        XCTAssertTrue(RouteStub.on(RouteStub.normalHost).isEmpty)
    }

    // MARK: - Review A2: a reconnect must not start the skip

    func testFallbackDoesNotWaitForTheNetwork() {
        // The fallback to the normal host must not wait for connectivity: if it did, a network
        // that comes back during the wait would answer 200 and start the 10-minute skip
        // although the tracking host never failed with a network present.
        let client = self.client(start: 3, now: 3)
        XCTAssertFalse(client.fallbackSessionWaitsForConnectivity)
    }

    func testReconnectAfterAnOfflineAttemptGoesToTheTrackingHost() async {
        let clock = Box<TimeInterval>(1_800_000_000)
        let client = fallbackClient(clock: clock)
        let online = Box(false)
        RouteStub.handler = { _, _ in online.value ? .status(200) : .failure(.notConnectedToInternet) }
        let queue = await makeQueue(client)
        queue.now = { clock.value }
        await queue.enqueue(payload(.real, eventId: "evt_offline"))
        XCTAssertEqual(queue.getStats().queueSize, 1, "kept while offline")
        XCTAssertEqual(client.trackingHostAvoidedUntil, 0, "offline: no skip")

        online.value = true          // the network comes back
        clock.value = queue.retryNotBefore + 0.001
        await queue.flush()
        XCTAssertEqual(queue.getStats().queueSize, 0)
        XCTAssertEqual(RouteStub.requests.last?.host, RouteStub.trackingHost, "the id goes to the tracking host")
        XCTAssertEqual(RouteStub.requests.last?.properties["idfa"] as? String, Self.idfa)
        XCTAssertEqual(client.trackingHostAvoidedUntil, 0, "a reconnect starts no skip")
    }

    // MARK: - No head-of-line stall

    private func makeQueue(_ client: DatalyrHTTPClient) async -> DatalyrEventQueue {
        let queue = DatalyrEventQueue(httpClient: client, config: QueueConfig(
            maxQueueSize: 100, batchSize: 10, flushInterval: 3600, maxRetryCount: 10), startsNetworkMonitor: false)
        queue.scheduleRetry = { _ in }
        await queue.waitForInitialization()
        return queue
    }

    func testBlockedTrackingHostDoesNotHoldTheQueue() async {
        // 2.3.0 with routing fixed but no fallback: each blocked event would be retried by the
        // queue's backoff and hold every later event behind it.
        let client = self.client(start: 3, now: 3)
        RouteStub.handler = { host, _ in host == RouteStub.trackingHost ? .failure(.notConnectedToInternet) : .status(200) }
        let queue = await makeQueue(client)
        queue.holdImmediateFlush()
        let ids = (0..<5).map { "evt_hol_\($0)" }
        for id in ids { await queue.enqueue(payload(.real, eventId: id)) }
        await queue.releaseImmediateFlush()?.value
        await queue.flush()

        XCTAssertEqual(queue.getStats().queueSize, 0, "every event delivered in one pass")
        XCTAssertEqual(queue.retryNotBefore, 0, "the queue never paused")
        XCTAssertEqual(RouteStub.on(RouteStub.normalHost).map(\.eventId), ids, "in order, once each")
        XCTAssertEqual(RouteStub.on(RouteStub.trackingHost).count, 1, "one blocked request, then the cool-down")
    }

    func testStoredQueueFromAnAuthorizedLaunchAfterRevoke() async throws {
        // Saved by a launch that was authorized; the user turned tracking off in Settings and
        // the app was started again.
        let stored = [QueuedEvent(payload: payload(.real, eventId: "evt_stored_1"), timestamp: 1_700_000_000),
                      QueuedEvent(payload: payload(.real, eventId: "evt_stored_2"), timestamp: 1_700_000_001)]
        await DatalyrStorage.shared.setCodableArray(StorageKeys.eventQueue, value: stored)
        let queue = await makeQueue(client(start: 2, now: 2))
        await queue.flush()
        XCTAssertEqual(queue.getStats().queueSize, 0)
        XCTAssertEqual(RouteStub.requests.map(\.host), [RouteStub.normalHost, RouteStub.normalHost])
        for request in RouteStub.requests {
            XCTAssertFalse(request.rawBody.contains(Self.idfa))
            XCTAssertEqual(request.properties["att_status"] as? Int, 2)
            XCTAssertEqual(request.properties["advertiser_tracking_enabled"] as? Bool, false)
        }
    }

    // MARK: - Whole SDK: allowed mid-session, next-launch re-send

    /// One app process: the start status and the live status are injected for every reader.
    @discardableResult
    private func launch(start: UInt?, live: Box<UInt>, configure: (DatalyrSDK) -> Void = { _ in }) async throws -> DatalyrSDK {
        TrackingStatusAtStart.overrideForTesting = { start }
        PlatformIntegrationManager.liveStatusForTesting = { live.value }
        PlatformIntegrationManager.idfaForTesting = Self.idfa
        let sdk = DatalyrSDK()
        configure(sdk)
        try await sdk.initialize(config: DatalyrConfig(
            apiKey: "dk_test_route_key", endpoint: Self.normalEndpoint,
            maxRetries: 0, retryDelay: 0.05, timeout: 10, flushInterval: 3600,
            enableAutoEvents: false, enableAttribution: false
        ))
        await drain(sdk)
        return sdk
    }

    private func drain(_ sdk: DatalyrSDK) async {
        await sdk.flush()
        await waitUntil { sdk.getStatus().queueStats.queueSize == 0 }
        await sdk.flush()
    }

    private var resent: [RouteStub.Request] {
        RouteStub.requests.filter { $0.eventName == "$att_status" && $0.properties["resent"] as? Bool == true }
    }
    private func flag() async -> String? { await DatalyrStorage.shared.getString(StorageKeys.attIdWithheld) }

    func testAllowedMidSessionGoesToTheNormalHostAtOnceThenResendsOnceNextLaunch() async throws {
        let live = Box<UInt>(0)
        let first = try await launch(start: 0, live: live)
        await first.track("before_prompt")
        live.value = 3                                     // the user taps "Allow"
        await first.updateTrackingAuthorization(status: 3)
        await first.track("paywall_viewed")
        await drain(first)

        XCTAssertTrue(RouteStub.on(RouteStub.trackingHost).isEmpty, "no request to the blocked tracking host")
        for name in ["before_prompt", "$att_status", "paywall_viewed"] {
            let sent = RouteStub.requests.filter { $0.eventName == name }
            XCTAssertEqual(sent.count, 1, "\(name): sent once, on the first attempt")
            XCTAssertEqual(sent.first?.host, RouteStub.normalHost, name)
            XCTAssertFalse(sent.first?.rawBody.contains(Self.idfa) ?? true, "\(name): no IDFA")
        }
        let paywall = try XCTUnwrap(RouteStub.requests.first { $0.eventName == "paywall_viewed" })
        XCTAssertEqual(paywall.properties["att_status"] as? Int, 3, "the user did allow")
        XCTAssertEqual(paywall.properties["advertiser_tracking_enabled"] as? Bool, true)
        let noted = await flag()
        let grantId = try XCTUnwrap(noted, "the withheld id is noted for the next launch")
        XCTAssertTrue(grantId.hasPrefix("att_resend_"))
        let anonymousId = paywall.anonymousId

        // Next launch starts authorized: $att_status once, with the IDFA, to the tracking host.
        let second = try await launch(start: 3, live: live)
        XCTAssertEqual(resent.count, 1)
        let resend = try XCTUnwrap(resent.first)
        XCTAssertEqual(resend.host, RouteStub.trackingHost)
        XCTAssertEqual(resend.properties["idfa"] as? String, Self.idfa)
        XCTAssertEqual(resend.eventId, grantId, "fixed event id per grant")
        XCTAssertEqual(resend.anonymousId, anonymousId, "same device ids")
        let flagAfter = await flag()
        XCTAssertNil(flagAfter)
        await second.track("after_relaunch")
        await drain(second)
        let after = try XCTUnwrap(RouteStub.requests.first { $0.eventName == "after_relaunch" })
        XCTAssertEqual(after.host, RouteStub.trackingHost)
        XCTAssertEqual(after.properties["idfa"] as? String, Self.idfa)

        // A third launch sends nothing more.
        try await launch(start: 3, live: live)
        XCTAssertEqual(resent.count, 1, "re-sent exactly once")
    }

    func testPromptBeforeTheSDKStartsInTheSameLaunch() async throws {
        // The app shows the prompt before initialize(); the user allows. The SDK's own start-up
        // events (sent in the background right after initialize()) follow the same rule.
        let live = Box<UInt>(3)
        try await launch(start: 0, live: live)
        XCTAssertFalse(RouteStub.requests.isEmpty)
        XCTAssertTrue(RouteStub.on(RouteStub.trackingHost).isEmpty)
        XCTAssertFalse(RouteStub.requests.contains { $0.rawBody.contains(Self.idfa) })
        let noted = await flag()
        XCTAssertNotNil(noted)
    }

    func testResendSurvivesAKillBetweenQueueingAndClearingTheFlag() async throws {
        let live = Box<UInt>(3)
        await DatalyrStorage.shared.setString(StorageKeys.attIdWithheld, value: "att_resend_fixed")
        try await launch(start: 3, live: live) { $0.stopBeforeAttResendFlagRemovalForTesting = true }
        let kept = await flag()
        XCTAssertEqual(kept, "att_resend_fixed", "killed before the flag was removed")
        try await launch(start: 3, live: live)
        try await launch(start: 3, live: live)
        XCTAssertEqual(resent.map(\.eventId), ["att_resend_fixed", "att_resend_fixed"],
                       "sent again after the kill with the same event id (the server keeps one), then never")
        let cleared = await flag()
        XCTAssertNil(cleared)
    }

    func testNoResendWhenRevokedOrForAlreadyAuthorizedUsers() async throws {
        // Revoked before the next launch: the flag is dropped, nothing is sent.
        await DatalyrStorage.shared.setString(StorageKeys.attIdWithheld, value: "att_resend_revoked")
        try await launch(start: 2, live: Box<UInt>(2))
        let dropped = await flag()
        XCTAssertNil(dropped)
        XCTAssertTrue(resent.isEmpty)

        // Already authorized at start (an upgrade from 2.3.0): no flag, no burst.
        try await launch(start: 3, live: Box<UInt>(3))
        XCTAssertTrue(resent.isEmpty)
        let none = await flag()
        XCTAssertNil(none)
    }

    func testUnreadableStartKeepsTheFlagForALaterLaunch() async throws {
        await DatalyrStorage.shared.setString(StorageKeys.attIdWithheld, value: "att_resend_later")
        try await launch(start: nil, live: Box<UInt>(3))
        XCTAssertTrue(resent.isEmpty)
        XCTAssertTrue(RouteStub.on(RouteStub.trackingHost).isEmpty, "unreadable start: normal host")
        let kept = await flag()
        XCTAssertEqual(kept, "att_resend_later")
        try await launch(start: 3, live: Box<UInt>(3))
        XCTAssertEqual(resent.map(\.eventId), ["att_resend_later"])
    }
}
