import XCTest
@testable import DatalyrSDK

/// Ingest that accepts the connection and does not answer until `answerAfter` (a hung or
/// captive-portal connection, an ingest outage). Requests that start after that time are
/// answered at once. Records every answered event in order.
final class HungIngestStub: URLProtocol {
    private static let lock = NSLock()
    private static var _answerAfter = Date.distantPast
    private static var _started = 0
    private static var _delivered: [String] = []

    static var started: Int { lock.withLock { _started } }
    /// Event names answered with 200, in answer order.
    static var delivered: [String] { lock.withLock { _delivered } }
    static var answerAfter: Date {
        get { lock.withLock { _answerAfter } }
        set { lock.withLock { _answerAfter = newValue } }
    }
    static func reset() { lock.withLock { _answerAfter = .distantPast; _started = 0; _delivered = [] } }

    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "hung-ingest.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let name = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["event"] as? String ?? "?"
        let wait: TimeInterval = Self.lock.withLock {
            Self._started += 1
            return max(Self._answerAfter.timeIntervalSinceNow, 0)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [self] in
            let answered: Bool = Self.lock.withLock {
                guard !cancelled else { return false }
                Self._delivered.append(name)
                return true
            }
            guard answered else { return }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"success":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.lock.withLock { cancelled = true } }
}

/// initialize() must not wait on the event endpoint. With a path to the network but an
/// endpoint that hangs, 2.2.0 and the 2.3.0 candidate waited for the first send (up to the
/// session's resource timeout, 30 s on a phone) before returning.
final class StartupNetworkWaitTests: XCTestCase {

    private static let storageKeys = [
        StorageKeys.eventQueue, "datalyr_app_install_tracked", StorageKeys.installClass,
        StorageKeys.existingUserInstall, StorageKeys.firstLaunchTime,
    ]
    private var savedProvider: (() async -> InstallSignals)!

    override func setUp() async throws {
        try await super.setUp()
        HungIngestStub.reset()
        DatalyrHTTPClient.protocolClassesForTesting = [HungIngestStub.self]
        savedProvider = DatalyrSDK.installSignalsProvider
        // A fresh install, so this launch sends app_install.
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
        DatalyrSDK.installSignalsProvider = savedProvider
        HungIngestStub.reset()
        for key in Self.storageKeys { await DatalyrStorage.shared.removeValue(key) }
        try await super.tearDown()
    }

    private static let ours: Set<String> = ["startup_pre_init", "app_install", "startup_after_init"]

    func testInitializeDoesNotWaitForAHungEndpointAndDeliversInstallOnceInOrder() async throws {
        // The endpoint hangs for 10 s, then answers (the connection comes back).
        HungIngestStub.answerAfter = Date().addingTimeInterval(10)

        let sdk = DatalyrSDK()
        await sdk.track("startup_pre_init")  // buffered before init, replayed by initialize()

        let start = Date()
        try await sdk.initialize(config: DatalyrConfig(
            apiKey: "dk_test",
            endpoint: "https://hung-ingest.test/track",
            maxRetries: 0,
            retryDelay: 0.05,
            timeout: 30,
            flushInterval: 3600,
            enableAutoEvents: false,
            enableAttribution: false
        ))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4.0, "initialize() waited \(String(format: "%.1f", elapsed)) s on the event endpoint")

        // Before initialize() returned, the start-up events were saved to the queue, in order.
        let persisted = await DatalyrStorage.shared.getCodableArray(StorageKeys.eventQueue, type: QueuedEvent.self) ?? []
        let persistedOurs = persisted.map(\.payload.eventName).filter { Self.ours.contains($0) }
        XCTAssertEqual(persistedOurs, ["startup_pre_init", "app_install"], "start-up events not saved before initialize() returned")
        let installMarker = await DatalyrStorage.shared.getString("datalyr_app_install_tracked")
        XCTAssertNotNil(installMarker)

        await sdk.track("startup_after_init")

        // Once the endpoint answers, every event is delivered exactly once, in order.
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let got = Set(HungIngestStub.delivered.filter { Self.ours.contains($0) })
            if got == Self.ours && sdk.getStatus().queueStats.queueSize == 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await sdk.flush()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let delivered = HungIngestStub.delivered.filter { Self.ours.contains($0) }
        XCTAssertEqual(delivered, ["startup_pre_init", "app_install", "startup_after_init"],
                       "each start-up event delivered once, install before later events")
        XCTAssertEqual(sdk.getStatus().queueStats.queueSize, 0)

        // Next launch: nothing is sent twice and no second install.
        let relaunched = DatalyrSDK()
        try await relaunched.initialize(config: DatalyrConfig(
            apiKey: "dk_test", endpoint: "https://hung-ingest.test/track",
            maxRetries: 0, retryDelay: 0.05, timeout: 10, flushInterval: 3600,
            enableAutoEvents: false, enableAttribution: false
        ))
        await relaunched.flush()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(HungIngestStub.delivered.filter { Self.ours.contains($0) }, delivered,
                       "a relaunch resent a delivered start-up event")
    }
}
