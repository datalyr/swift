import XCTest
@testable import DatalyrSDK

/// Stubs POST /track for DatalyrHTTPClient sessions created while it is installed
/// (DatalyrHTTPClient.protocolClassesForTesting). Each request is answered by `handler`
/// and its `eventId` recorded.
final class IngestStub: URLProtocol {
    enum Answer {
        case status(Int, headers: [String: String])
        case failure(URLError.Code)
        static func status(_ code: Int) -> Answer { .status(code, headers: [:]) }
    }

    private static let lock = NSLock()
    private static var _eventIds: [String] = []
    private static var _handler: (String) -> Answer = { _ in .status(200) }

    static var eventIds: [String] { lock.withLock { _eventIds } }
    static var handler: (String) -> Answer {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    /// Answer the next requests in this order; after the list, 200.
    static func script(_ answers: [Answer]) {
        let box = ScriptBox(answers)
        handler = { _ in box.next() }
    }
    static func reset() {
        lock.withLock { _eventIds = []; _handler = { _ in .status(200) } }
    }

    private final class ScriptBox {
        private let lock = NSLock()
        private var answers: [Answer]
        init(_ a: [Answer]) { answers = a }
        func next() -> Answer { lock.withLock { answers.isEmpty ? .status(200) : answers.removeFirst() } }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.path == "/track" }
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
        let eventId = body["eventId"] as? String ?? ""
        let handler: (String) -> Answer = Self.lock.withLock {
            Self._eventIds.append(eventId)
            return Self._handler
        }
        switch handler(eventId) {
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

/// FX-047 piece 1 (iOS): events are kept on 5xx, 503, 429, timeouts and network errors and
/// retried with backoff and the same event id; only a final 4xx drops them; Retry-After is
/// honoured; the dead-letter cap is tested and what it drops is counted.
///
/// Time is a fake clock (DatalyrEventQueue.now) and retries are driven by flush(), so no
/// test waits for a real backoff.
final class EventDeliveryRetryTests: XCTestCase {

    private final class Clock {
        private let lock = NSLock()
        private var t: TimeInterval = 1_800_000_000
        var now: TimeInterval { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
        func set(_ v: TimeInterval) { lock.withLock { t = v } }
    }

    private var clock = Clock()
    private var queues: [DatalyrEventQueue] = []

    override func setUp() async throws {
        try await super.setUp()
        IngestStub.reset()
        DatalyrHTTPClient.protocolClassesForTesting = [IngestStub.self]
        clock = Clock()
        await clearStorage()
    }

    override func tearDown() async throws {
        queues = [] // not destroy(): its detached persist could land in the next test's storage
        DatalyrHTTPClient.protocolClassesForTesting = nil
        IngestStub.reset()
        await clearStorage()
        try await super.tearDown()
    }

    private func clearStorage() async {
        await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
        await DatalyrStorage.shared.removeValue(StorageKeys.deadLetterQueue)
        for reason in DatalyrEventQueue.DropReason.allCases {
            await DatalyrStorage.shared.removeValue(DatalyrEventQueue.dropCountKey(reason))
        }
    }

    private func makeQueue(maxQueueSize: Int = 1000, maxRetryCount: Int = QueueConfig.minTransientAttempts) async -> DatalyrEventQueue {
        let client = DatalyrHTTPClient(endpoint: "https://ingest.example.invalid/track",
                                       config: HTTPClientConfig(apiKey: "dk_fake_test_key"))
        let queue = DatalyrEventQueue(httpClient: client, config: QueueConfig(
            maxQueueSize: maxQueueSize, batchSize: 10, flushInterval: 3600, maxRetryCount: maxRetryCount))
        let clock = self.clock
        queue.now = { clock.now }
        queue.scheduleRetry = { _ in }   // the test drives every retry
        queues.append(queue)
        await queue.waitForInitialization()
        return queue
    }

    private func payload(_ name: String = "signup", id: String = UUID().uuidString) -> EventPayload {
        EventPayload(workspaceId: "ws_test", visitorId: "vis_test", anonymousId: "anon_test",
                     sessionId: "sess_test", eventId: id, eventName: name)
    }

    /// Move the clock to the queue's gate and flush.
    private func retryNow(_ queue: DatalyrEventQueue) async {
        clock.set(max(clock.now, queue.retryNotBefore) + 0.001)
        await queue.flush()
    }

    private func deadLetter() async -> [QueuedEvent] {
        await DatalyrStorage.shared.getCodableArray(StorageKeys.deadLetterQueue, type: QueuedEvent.self) ?? []
    }

    // MARK: - what counts as delivered

    func testAny2xxIsDeliveredAndNeverSentAgain() async {
        for code in [200, 201, 202, 204] {
            IngestStub.reset()
            await clearStorage()
            IngestStub.script([.status(code)])
            let queue = await makeQueue()
            await queue.enqueue(payload(id: "evt_2xx_\(code)"))
            XCTAssertEqual(queue.getStats().queueSize, 0, "HTTP \(code) is stored")
            clock.advance(3600)
            await queue.flush()
            XCTAssertEqual(IngestStub.eventIds, ["evt_2xx_\(code)"], "an accepted event is never re-sent (HTTP \(code))")
        }
    }

    func testDuplicateAnswerIsDelivered() async {
        // Ingest answers a repeated event id with 200 {success:false, error:"Duplicate event detected"}.
        IngestStub.script([.status(200)])
        let queue = await makeQueue()
        await queue.enqueue(payload(id: "evt_dup"))
        XCTAssertEqual(queue.getStats().queueSize, 0)
    }

    // MARK: - kept and retried with the same event id

    func testServerErrorKeepsEventAndRetriesSameEventId() async {
        IngestStub.script([.status(500), .status(502), .status(200)])
        let queue = await makeQueue()
        await queue.enqueue(payload(id: "evt_5xx"))
        XCTAssertEqual(queue.getStats().queueSize, 1, "kept after a 500")

        await queue.flush() // before the backoff: nothing is sent
        XCTAssertEqual(IngestStub.eventIds.count, 1, "no retry before the backoff has passed")

        await retryNow(queue)
        XCTAssertEqual(queue.getStats().queueSize, 1, "kept after a 502")
        await retryNow(queue)
        XCTAssertEqual(queue.getStats().queueSize, 0)
        XCTAssertEqual(IngestStub.eventIds, ["evt_5xx", "evt_5xx", "evt_5xx"], "every retry carries the same event id")
        let dead = await deadLetter()
        XCTAssertTrue(dead.isEmpty)
        XCTAssertEqual(queue.getStats().droppedEvents, 0)

        clock.advance(3600)
        await queue.flush()
        XCTAssertEqual(IngestStub.eventIds.count, 3, "never re-sent after the 200")
    }

    func testBackoffDoublesAndIsCapped() async {
        IngestStub.handler = { _ in .status(500) }
        let queue = await makeQueue(maxRetryCount: 50)
        await queue.enqueue(payload(id: "evt_backoff"))
        var waits: [TimeInterval] = []
        for _ in 0..<12 {
            waits.append(queue.retryNotBefore - clock.now)
            await retryNow(queue)
        }
        for (i, wait) in waits.enumerated() {
            let base = min(pow(2.0, Double(i)), DatalyrEventQueue.maxBackoff)
            XCTAssertGreaterThanOrEqual(wait, base - 0.01, "wait \(i)")
            XCTAssertLessThanOrEqual(wait, min(base * 1.25, DatalyrEventQueue.maxBackoff) + 0.01, "wait \(i)")
        }
        XCTAssertEqual(waits.last ?? 0, DatalyrEventQueue.maxBackoff, accuracy: 0.01, "capped at 5 minutes")
    }

    func test503HonoursRetryAfter() async {
        IngestStub.script([.status(503, headers: ["Retry-After": "5"]), .status(200)])
        let queue = await makeQueue()
        await queue.enqueue(payload(id: "evt_503"))
        let wait = queue.retryNotBefore - clock.now
        XCTAssertGreaterThanOrEqual(wait, 5 - 0.001, "never earlier than Retry-After")
        XCTAssertLessThanOrEqual(wait, 5 * 1.25 + 0.001, "at most 25% jitter")

        clock.advance(4.9)
        await queue.flush()
        XCTAssertEqual(IngestStub.eventIds.count, 1, "not before Retry-After")
        await retryNow(queue)
        XCTAssertEqual(IngestStub.eventIds, ["evt_503", "evt_503"])
        XCTAssertEqual(queue.getStats().queueSize, 0)
    }

    func test429HonoursRetryAfterAndSpendsNoAttempt() async {
        let maxRetry = 3
        IngestStub.script(Array(repeating: .status(429, headers: ["Retry-After": "60"]), count: maxRetry + 2) + [.status(200)])
        let queue = await makeQueue(maxRetryCount: maxRetry)
        await queue.enqueue(payload(id: "evt_429"))
        for _ in 0..<(maxRetry + 1) {
            let wait = queue.retryNotBefore - clock.now
            XCTAssertGreaterThanOrEqual(wait, 60 - 0.001)
            XCTAssertLessThanOrEqual(wait, 75 + 0.001)
            await retryNow(queue)
        }
        await retryNow(queue)
        XCTAssertEqual(queue.getStats().queueSize, 0, "delivered once the throttle lifts")
        XCTAssertEqual(Set(IngestStub.eventIds), ["evt_429"])
        let dead = await deadLetter()
        XCTAssertFalse(dead.contains { $0.payload.eventId == "evt_429" }, "429 never spends the attempts that lead to dead-letter")
    }

    func testTimeoutsAndNetworkErrorsKeepTheEvent() async {
        // Timeout, offline, DNS, TLS and a cancelled request are connectivity, not a verdict.
        let codes: [URLError.Code] = [.timedOut, .notConnectedToInternet, .cannotFindHost,
                                      .dnsLookupFailed, .secureConnectionFailed, .cancelled, .networkConnectionLost]
        IngestStub.script(codes.map { .failure($0) } + [.status(200)])
        let queue = await makeQueue(maxRetryCount: 50)
        await queue.enqueue(payload(id: "evt_net"))
        for _ in codes {
            XCTAssertEqual(queue.getStats().queueSize, 1)
            await retryNow(queue)
        }
        XCTAssertEqual(queue.getStats().queueSize, 0)
        XCTAssertEqual(IngestStub.eventIds, Array(repeating: "evt_net", count: codes.count + 1))
        XCTAssertEqual(queue.getStats().droppedEvents, 0)
    }

    func testFailureStopsTheBatchSoAnOutageIsProbedOnce() async {
        IngestStub.handler = { _ in .status(503) }
        let queue = await makeQueue()
        queue.setOnlineStatus(false)
        for i in 0..<5 { await queue.enqueue(payload(id: "evt_batch_\(i)")) }
        queue.setOnlineStatus(true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(IngestStub.eventIds, ["evt_batch_0"], "one request while the server is failing, not one per event")
        XCTAssertEqual(queue.getStats().queueSize, 5)
    }

    /// FX-047 "done means": a 2-minute 5xx outage loses nothing, and nothing is sent twice
    /// after it was stored.
    func testTwoMinuteOutageLosesNothing() async {
        let clock = self.clock
        let outageEnds = clock.now + 120
        IngestStub.handler = { _ in clock.now < outageEnds ? .status(503) : .status(200) }
        let queue = await makeQueue()
        let ids = (0..<25).map { "evt_outage_\($0)" }
        for id in ids { await queue.enqueue(payload(id: id)) }

        var rounds = 0
        while queue.getStats().queueSize > 0 && rounds < 100 {
            await retryNow(queue)
            rounds += 1
        }
        XCTAssertEqual(queue.getStats().queueSize, 0, "everything delivered after the outage")
        XCTAssertGreaterThan(clock.now, outageEnds)
        XCTAssertEqual(Set(IngestStub.eventIds), Set(ids), "every event reached the server")
        // Each event was stored exactly once: after the outage every id is sent once.
        let afterOutage = Array(IngestStub.eventIds.suffix(ids.count))
        XCTAssertEqual(afterOutage.sorted(), ids.sorted(), "no event sent again after a 200")
        let dead = await deadLetter()
        XCTAssertTrue(dead.isEmpty, "nothing dead-lettered by a 2-minute outage")
        XCTAssertEqual(queue.getStats().droppedEvents, 0)
    }

    func testAttemptCapMovesToDeadLetterNotDropped() async {
        IngestStub.handler = { _ in .status(500) }
        let queue = await makeQueue(maxRetryCount: 3)
        await queue.enqueue(payload("purchase", id: "evt_cap"))
        await retryNow(queue)
        await retryNow(queue)
        XCTAssertEqual(queue.getStats().queueSize, 0)
        XCTAssertEqual(IngestStub.eventIds, ["evt_cap", "evt_cap", "evt_cap"])
        let dead = await deadLetter()
        XCTAssertTrue(dead.contains { $0.payload.eventId == "evt_cap" }, "kept in the dead-letter store, replayed next launch")
        XCTAssertEqual(queue.getStats().droppedEvents, 0, "dead-lettered is not dropped")
    }

    // MARK: - only a final 4xx drops

    func testFinal4xxIsDroppedAtOnceAndCounted() async {
        for code in [400, 405, 413, 415, 422] {
            IngestStub.reset()
            await clearStorage()
            IngestStub.script([.status(code)])
            let queue = await makeQueue()
            let failed = NSLock()
            var hookCalls = 0
            queue.onDeadLetter = { _, _ in failed.withLock { hookCalls += 1 } }
            await queue.enqueue(payload(id: "evt_final_\(code)"))
            XCTAssertEqual(queue.getStats().queueSize, 0, "HTTP \(code) is final")
            XCTAssertEqual(queue.getStats().droppedEventsByReason["rejected"], 1, "HTTP \(code) is counted")
            XCTAssertEqual(failed.withLock { hookCalls }, 1, "the app's delegate hears about it")
            clock.advance(3600)
            await queue.flush()
            XCTAssertEqual(IngestStub.eventIds, ["evt_final_\(code)"], "a refused event is never sent again")
            let dead = await deadLetter()
            XCTAssertFalse(dead.contains { $0.payload.eventId == "evt_final_\(code)" }, "not parked for replay")
        }
    }

    func testRefusedKeyOr404IsRetriedForTenMinutesThenDroppedAndCounted() async {
        // 404: ingest never answers it; an edge misroute must not wipe events on every phone.
        for code in [401, 403, 404] {
            IngestStub.reset()
            await clearStorage()
            IngestStub.handler = { _ in .status(code) }
            let queue = await makeQueue()
            await queue.enqueue(payload(id: "evt_auth_\(code)"))
            XCTAssertEqual(queue.getStats().queueSize, 1, "kept: the key may be fixed")
            clock.advance(5 * 60)
            await queue.flush()
            XCTAssertEqual(queue.getStats().queueSize, 1, "still kept after 5 minutes")
            clock.advance(5 * 60)
            await queue.flush()
            XCTAssertEqual(queue.getStats().queueSize, 0, "dropped after 10 minutes of refusals")
            XCTAssertEqual(queue.getStats().droppedEventsByReason["refused"], 1)
            XCTAssertEqual(Set(IngestStub.eventIds), ["evt_auth_\(code)"])
        }
    }

    func testRefusedKeyThatIsFixedDeliversTheEvent() async {
        IngestStub.script([.status(401), .status(200)])
        let queue = await makeQueue()
        await queue.enqueue(payload(id: "evt_auth_fixed"))
        await retryNow(queue)
        XCTAssertEqual(queue.getStats().queueSize, 0)
        XCTAssertEqual(queue.getStats().droppedEvents, 0)
    }

    // MARK: - caps and counting

    func testDeadLetterCapDropsAnalyticsFirstAndCounts() async {
        let queue = await makeQueue(maxQueueSize: 1)
        queue.setOnlineStatus(false)
        // A full dead-letter store: one purchase (oldest) and 99 analytics events.
        let full = [QueuedEvent(payload: payload("purchase", id: "evt_dl_purchase"))]
            + (0..<(DatalyrEventQueue.maxDeadLetter - 1)).map { QueuedEvent(payload: payload("pageview", id: "evt_dl_\($0)")) }
        await DatalyrStorage.shared.setCodableArray(StorageKeys.deadLetterQueue, value: full)

        await queue.enqueue(payload("pageview", id: "evt_live_1"))
        await queue.enqueue(payload("pageview", id: "evt_live_2")) // evicts evt_live_1 into the full store

        let dead = await deadLetter()
        XCTAssertEqual(dead.count, DatalyrEventQueue.maxDeadLetter, "the store stays capped")
        XCTAssertTrue(dead.contains { $0.payload.eventId == "evt_dl_purchase" }, "the purchase is kept")
        XCTAssertFalse(dead.contains { $0.payload.eventId == "evt_dl_0" }, "the oldest analytics event goes")
        XCTAssertTrue(dead.contains { $0.payload.eventId == "evt_live_1" })
        XCTAssertEqual(queue.getStats().droppedEventsByReason["dead_letter_full"], 1, "what the cap drops is counted")
    }

    func testExpiredDeadLetterEntriesAreCounted() async {
        await DatalyrStorage.shared.setCodableArray(StorageKeys.deadLetterQueue, value: [
            QueuedEvent(payload: payload(id: "evt_exhausted"), retryCount: 3, replayCount: DatalyrEventQueue.maxDeadLetterReplays),
            QueuedEvent(payload: payload(id: "evt_stale"), timestamp: Date().timeIntervalSince1970 - DatalyrEventQueue.maxDeadLetterAge - 60, retryCount: 3),
        ])
        let queue = await makeQueue()
        XCTAssertEqual(queue.getStats().droppedEventsByReason["dead_letter_expired"], 2)
    }

    func testDropCountsSurviveARelaunch() async {
        IngestStub.script([.status(400)])
        let first = await makeQueue()
        await first.enqueue(payload(id: "evt_count"))
        XCTAssertEqual(first.getStats().droppedEvents, 1)
        let second = await makeQueue()
        XCTAssertGreaterThanOrEqual(second.getStats().droppedEventsByReason["rejected"] ?? 0, 1)
    }

    // MARK: - classification and storage compatibility

    func testAnswerClassification() {
        typealias C = DatalyrHTTPClient
        XCTAssertEqual(C.disposition(forStatus: 200, retryAfter: nil), .delivered)
        XCTAssertEqual(C.disposition(forStatus: 204, retryAfter: nil), .delivered)
        XCTAssertEqual(C.disposition(forStatus: 503, retryAfter: 5), .retry(after: 5))
        XCTAssertEqual(C.disposition(forStatus: 500, retryAfter: nil), .retry(after: nil))
        XCTAssertEqual(C.disposition(forStatus: 429, retryAfter: 1), .throttled(after: 1))
        XCTAssertEqual(C.disposition(forStatus: 408, retryAfter: nil), .throttled(after: nil))
        XCTAssertEqual(C.disposition(forStatus: 401, retryAfter: nil), .refused)
        XCTAssertEqual(C.disposition(forStatus: 403, retryAfter: nil), .refused)
        XCTAssertEqual(C.disposition(forStatus: 404, retryAfter: nil), .refused)
        XCTAssertEqual(C.disposition(forStatus: 400, retryAfter: nil), .rejected)
        XCTAssertEqual(C.disposition(forStatus: 413, retryAfter: nil), .rejected)
        XCTAssertEqual(C.disposition(forError: URLError(.timedOut)), .retry(after: nil))
        XCTAssertEqual(C.disposition(forError: URLError(.cannotFindHost)), .retry(after: nil))
        XCTAssertEqual(C.disposition(forError: URLError(.serverCertificateUntrusted)), .retry(after: nil))
        XCTAssertEqual(C.disposition(forError: URLError(.cancelled)), .retry(after: nil))
        XCTAssertEqual(C.disposition(forError: URLError(.badURL)), .rejected)
    }

    func testRetryAfterIsClampedToFiveMinutes() async {
        IngestStub.script([.status(503, headers: ["Retry-After": "86400"])])
        let queue = await makeQueue()
        await queue.enqueue(payload(id: "evt_clamp"))
        XCTAssertEqual(queue.retryNotBefore - clock.now, DatalyrEventQueue.maxBackoff, accuracy: 0.01)
    }

    func testRetryAfterGetsZeroTo25PercentJitterCappedAt300() {
        var waits: [TimeInterval] = []
        for _ in 0..<500 { waits.append(DatalyrEventQueue.retryAfterWait(60)) }
        XCTAssertGreaterThanOrEqual(waits.min() ?? 0, 60)
        XCTAssertLessThanOrEqual(waits.max() ?? 0, 75)
        XCTAssertGreaterThan(Set(waits).count, 1, "jittered, not a fixed value")
        for _ in 0..<200 {
            let w = DatalyrEventQueue.retryAfterWait(280)
            XCTAssertGreaterThanOrEqual(w, 280)
            XCTAssertLessThanOrEqual(w, DatalyrEventQueue.maxBackoff)
        }
    }

    func testBatchThatDeliversSomeThenFailsKeepsOnlyTheUndelivered() async {
        IngestStub.script([.status(200), .status(200), .status(503)])
        let queue = await makeQueue()
        queue.setOnlineStatus(false)
        let ids = (0..<5).map { "evt_part_\($0)" }
        for id in ids { await queue.enqueue(payload(id: id)) }
        queue.setOnlineStatus(true)
        await queue.flush()
        XCTAssertEqual(IngestStub.eventIds, Array(ids.prefix(3)), "two delivered, the third failed, the batch stopped")
        let persisted = await DatalyrStorage.shared.getCodableArray(StorageKeys.eventQueue, type: QueuedEvent.self) ?? []
        XCTAssertEqual(queue.getStats().queueSize, 3)
        XCTAssertEqual(persisted.map { $0.payload.eventId }, Array(ids.suffix(3)), "delivered events are not re-queued")
        XCTAssertEqual(persisted.first?.retryCount, 1, "the failed event keeps its own record, not a new one")

        await retryNow(queue)
        XCTAssertEqual(queue.getStats().queueSize, 0)
        var sends: [String: Int] = [:]
        for id in IngestStub.eventIds { sends[id, default: 0] += 1 }
        XCTAssertEqual(sends, ["evt_part_0": 1, "evt_part_1": 1, "evt_part_2": 2, "evt_part_3": 1, "evt_part_4": 1])
    }

    // MARK: - ledger: one lock for the dead-letter store and the counts

    func testConcurrentDeadLetterWritesLoseNothing() async {
        let ledger = QueueLedger()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<60 {
                group.addTask {
                    ledger.appendDeadLetter(QueuedEvent(payload: self.payload(id: "evt_conc_\(i)")),
                                            capacity: 100, isCritical: { _ in false })
                }
            }
        }
        let ids = Set(ledger.deadLetterEntries().map { $0.payload.eventId })
        XCTAssertEqual(ids, Set((0..<60).map { "evt_conc_\($0)" }), "every concurrent write is kept")
    }

    func testConcurrentOverflowIsCountedExactly() async {
        let ledger = QueueLedger()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<150 {
                group.addTask {
                    ledger.appendDeadLetter(QueuedEvent(payload: self.payload(id: "evt_ovf_\(i)")),
                                            capacity: 100, isCritical: { _ in false })
                }
            }
        }
        XCTAssertEqual(ledger.deadLetterEntries().count, 100)
        XCTAssertEqual(ledger.dropCounts()["dead_letter_full"], 50, "every overflow drop counted once")
    }

    func testConcurrentCountsNeverGoDown() async {
        let ledger = QueueLedger()
        let totals: [Int] = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<300 { group.addTask { ledger.countDrop(.rejected) } }
            var all: [Int] = []
            for await t in group { all.append(t) }
            return all
        }
        XCTAssertEqual(Set(totals).count, 300, "each count saw its own new total")
        XCTAssertEqual(totals.max(), 300)
        XCTAssertEqual(ledger.dropCounts()["rejected"], 300, "the stored total is the last, highest one")
    }

    // MARK: - launch order

    func testReplayedDeadLettersAreSavedBeforeTheStoreIsCleared() async {
        await DatalyrStorage.shared.setCodableArray(StorageKeys.deadLetterQueue, value: [
            QueuedEvent(payload: payload("purchase", id: "evt_replay_order"), retryCount: 3),
        ])
        let client = DatalyrHTTPClient(endpoint: "https://ingest.example.invalid/track",
                                       config: HTTPClientConfig(apiKey: "dk_fake_test_key"))
        let seen = NSLock()
        var inQueueAtHook = false
        var inDeadLetterAtHook = false
        // The hook must be set before initializeQueue runs, so build the queue offline and
        // set it straight away; initializeQueue starts on a Task after init returns.
        let queue = DatalyrEventQueue(httpClient: client, config: QueueConfig(flushInterval: 3600))
        queue.afterReplayPersistForTesting = {
            let q = DatalyrStorage.shared.getCodableArraySync(StorageKeys.eventQueue, type: QueuedEvent.self) ?? []
            let d = DatalyrStorage.shared.getCodableArraySync(StorageKeys.deadLetterQueue, type: QueuedEvent.self) ?? []
            seen.withLock {
                inQueueAtHook = q.contains { $0.payload.eventId == "evt_replay_order" }
                inDeadLetterAtHook = d.contains { $0.payload.eventId == "evt_replay_order" }
            }
        }
        queue.setOnlineStatus(false)
        queues.append(queue)
        await queue.waitForInitialization()
        seen.withLock {
            XCTAssertTrue(inQueueAtHook, "saved in the queue first")
            XCTAssertTrue(inDeadLetterAtHook, "still in the dead-letter store at that moment: a kill here loses nothing")
        }
        let dead = await deadLetter()
        XCTAssertFalse(dead.contains { $0.payload.eventId == "evt_replay_order" }, "removed afterwards")
    }

    func testDeadLetterAlreadyInTheQueueIsNotReplayedTwice() async {
        let event = QueuedEvent(payload: payload("purchase", id: "evt_both"), retryCount: 3)
        await DatalyrStorage.shared.setCodableArray(StorageKeys.eventQueue, value: [event])
        await DatalyrStorage.shared.setCodableArray(StorageKeys.deadLetterQueue, value: [event])
        let queue = await makeQueue()
        queue.setOnlineStatus(false)
        let persisted = await DatalyrStorage.shared.getCodableArray(StorageKeys.eventQueue, type: QueuedEvent.self) ?? []
        XCTAssertEqual(persisted.filter { $0.payload.eventId == "evt_both" }.count, 1)
    }

    func testQueuedEventDecodesWithoutAuthRefusedSince() throws {
        var event = QueuedEvent(payload: payload(id: "evt_legacy"), retryCount: 2)
        event.authRefusedSince = 123
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        XCTAssertEqual(json["authRefusedSince"] as? Double, 123, "persisted")
        json.removeValue(forKey: "authRefusedSince")
        let decoded = try JSONDecoder().decode(QueuedEvent.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.authRefusedSince)
        XCTAssertEqual(decoded.retryCount, 2)
    }
}
