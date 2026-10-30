import XCTest
@testable import DatalyrSDK

/// 2.2.0: a real install vs an existing user's first launch after an update added the SDK.
final class InstallClassifierTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private func signals(ranBefore: Bool?, bundleNewer: Bool? = false, container: Date? = nil,
                         store: StoreInstallRecord? = nil, build: String = "244") -> InstallSignals {
        InstallSignals(ranBefore: ranBefore, bundleNewerThanContainer: bundleNewer,
                       containerCreatedAt: container ?? now, store: store, currentBuild: build, now: now)
    }

    // MARK: - Decision matrix

    func testFreshInstallOfThisBuildIsNew() {
        let c = InstallClassifier.classify(signals(ranBefore: false, store: .init(originalAppVersion: "244", originalPurchaseDate: now)), hint: nil)
        XCTAssertEqual(c.type, .new)
        XCTAssertNil(c.priorInstallAge)
    }

    func testUpdateIntoTheSDKIsAnExistingUser() {
        // Container from last year, files written by earlier builds, App Store record at build 201.
        let c = InstallClassifier.classify(signals(ranBefore: true, bundleNewer: true, container: days(400),
                                                   store: .init(originalAppVersion: "201", originalPurchaseDate: days(400))), hint: nil)
        XCTAssertEqual(c.type, .existingUser)
        XCTAssertEqual(c.method, "bundle_vs_container")
        XCTAssertEqual(c.priorInstallAge, ">1y")
        XCTAssertEqual(c.originalAppVersion, "201")
    }

    func testBuildNumberResetStillExistingWhenTheAppWasUpdatedHere() {
        // 1.0(1) → 2.0(1): the record's build equals the current one, but the bundle is newer.
        let c = InstallClassifier.classify(signals(ranBefore: true, bundleNewer: true, container: days(90),
                                                   store: .init(originalAppVersion: "1", originalPurchaseDate: days(90)), build: "1"), hint: nil)
        XCTAssertEqual(c.type, .existingUser)
    }

    func testLateSDKStartOnTheFirstBuildIsNew() {
        // A consent / login gate: the app ran before the SDK started, same build, never updated.
        let c = InstallClassifier.classify(signals(ranBefore: true, bundleNewer: false, container: days(2),
                                                   store: .init(originalAppVersion: "244", originalPurchaseDate: days(2))), hint: nil)
        XCTAssertEqual(c.type, .new)
    }

    func testRanBeforeWithoutStoreRecordIsExisting() {
        // iOS 13-15, TestFlight, signed out: the app ran here before, nothing says otherwise.
        let c = InstallClassifier.classify(signals(ranBefore: true, bundleNewer: nil, container: days(40)), hint: nil)
        XCTAssertEqual(c.type, .existingUser)
        XCTAssertEqual(c.method, "ran_before")
        XCTAssertEqual(c.priorInstallAge, "30-365d")
    }

    func testDeleteAndReinstallIsReinstall() {
        let c = InstallClassifier.classify(signals(ranBefore: false, container: now,
                                                   store: .init(originalAppVersion: "150", originalPurchaseDate: days(200))), hint: nil)
        XCTAssertEqual(c.type, .reinstall)
        XCTAssertEqual(c.priorInstallAge, "30-365d")
    }

    func testAutoUpdatedBeforeFirstOpenIsNew() {
        // Installed build 243, auto-updated to 244, then opened: nothing ran before.
        let c = InstallClassifier.classify(signals(ranBefore: false, container: days(3),
                                                   store: .init(originalAppVersion: "243", originalPurchaseDate: days(3))), hint: nil)
        XCTAssertEqual(c.type, .new)
    }

    func testNoSignalsAtAllIsUnknown() {
        XCTAssertEqual(InstallClassifier.classify(signals(ranBefore: nil), hint: nil).type, .unknown)
        XCTAssertEqual(InstallClassifier.classify(signals(ranBefore: false), hint: nil).type, .new)
    }

    func testHostHintWins() {
        let c = InstallClassifier.classify(signals(ranBefore: false, store: .init(originalAppVersion: "244", originalPurchaseDate: now)), hint: true)
        XCTAssertEqual(c.type, .existingUser)
        XCTAssertEqual(c.method, "host_hint")
        // false / nil leave the decision to the device signals.
        XCTAssertEqual(InstallClassifier.classify(signals(ranBefore: false), hint: false).type, .new)
    }

    func testOnlyBucketsLeaveTheDevice() {
        let c = InstallClassifier.classify(signals(ranBefore: true, container: days(10)), hint: nil)
        XCTAssertEqual(Set(c.eventProperties.keys), ["install_type", "detection_method", "prior_install_age"])
        XCTAssertEqual(InstallClassifier.ageBucket(days(0.5), now: now), "<1d")
        XCTAssertEqual(InstallClassifier.ageBucket(days(3), now: now), "1-7d")
        XCTAssertEqual(InstallClassifier.ageBucket(days(10), now: now), "7-30d")
    }

    func testProcessStartIsReadable() {
        let start = DeviceInstallSignals.processStartDate()
        XCTAssertNotNil(start)
        XCTAssertLessThanOrEqual(start!, Date())
    }

    // MARK: - Real initialize()

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
    private var reads = Box(0)
    private var savedProvider: (() async -> InstallSignals)!

    private static func config(hint: (() -> Bool?)? = nil) -> DatalyrConfig {
        DatalyrConfig(apiKey: "dk_test", endpoint: "http://127.0.0.1:9/track", maxRetries: 0, retryDelay: 0.01,
                      timeout: 1, flushInterval: 3600, enableAutoEvents: false, enableAttribution: true,
                      existingUserHint: hint)
    }

    private static func clearInstallStorage() async {
        for key in ["datalyr_app_install_tracked", StorageKeys.installClass, StorageKeys.firstLaunchTime,
                    StorageKeys.eventQueue] {
            await DatalyrStorage.shared.removeValue(key)
        }
        await ATTDeferredLookupTests.clearLookupStorage()
    }

    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(DeferredLookupStub.self)
        DeferredLookupStub.reset()
        events = Box([])
        reads = Box(0)
        savedProvider = DatalyrSDK.installSignalsProvider
        await Self.clearInstallStorage()
    }

    override func tearDown() async throws {
        DatalyrSDK.installSignalsProvider = savedProvider
        URLProtocol.unregisterClass(DeferredLookupStub.self)
        DeferredLookupStub.reset()
        await Self.clearInstallStorage()
        try await super.tearDown()
    }

    private func provide(_ s: InstallSignals) {
        let reads = self.reads
        DatalyrSDK.installSignalsProvider = { reads.value += 1; return s }
    }

    private func launch(_ config: DatalyrConfig = config()) async throws -> DatalyrSDK {
        let sdk = DatalyrSDK()
        let events = self.events
        sdk.trackObserverForTesting = { name, data in events.value.append((name, data)) }
        try await sdk.initialize(config: config)
        return sdk
    }

    private func names() -> [String] { events.value.map(\.0) }
    private func data(_ name: String) -> EventData? { events.value.first { $0.0 == name }?.1 }

    func testExistingUserSendsItsOwnEventAndNoInstall() async throws {
        provide(signals(ranBefore: true, bundleNewer: true, container: days(300)))
        _ = try await launch()
        XCTAssertFalse(names().contains("app_install"), "\(names())")
        let existing = try XCTUnwrap(data("$sdk_first_launch_existing"))
        XCTAssertEqual(existing["install_type"] as? String, "existing_user")
        XCTAssertNil(existing["fbclid"])
        let resolved = await DatalyrStorage.shared.getBool(StorageKeys.deferredLookupResolved)
        XCTAssertEqual(resolved, true, "the deferred IP lookup never runs for an existing user")
        XCTAssertTrue(DeferredLookupStub.bodies.isEmpty)
        let tracked = await DatalyrStorage.shared.getString("datalyr_app_install_tracked")
        XCTAssertNotNil(tracked)

        // Next launch: nothing fires again, and nothing is re-read.
        events = Box([])
        _ = try await launch()
        XCTAssertFalse(names().contains("app_install"))
        XCTAssertFalse(names().contains("$sdk_first_launch_existing"))
        XCTAssertEqual(reads.value, 1)
    }

    func testNewInstallIsLabelled() async throws {
        provide(signals(ranBefore: false, store: .init(originalAppVersion: "244", originalPurchaseDate: now)))
        _ = try await launch()
        let install = try XCTUnwrap(data("app_install"))
        XCTAssertEqual(install["install_type"] as? String, "new")
        XCTAssertEqual(install["detection_method"] as? String, "app_transaction")
        XCTAssertFalse(names().contains("$sdk_first_launch_existing"))
    }

    func testAStoredClassIsReusedAfterAKillBeforeTheInstallWasQueued() async throws {
        // A previous launch decided "new" and died before app_install was enqueued; by now the
        // app has written files, so a fresh read would say ran-before. The stored class wins.
        let stored = InstallClassification(type: .new, method: "app_transaction", priorInstallAge: nil, originalAppVersion: "244")
        await DatalyrStorage.shared.setData(StorageKeys.installClass, value: try JSONEncoder().encode(stored))
        provide(signals(ranBefore: true, bundleNewer: true, container: days(1)))
        _ = try await launch()
        XCTAssertEqual(data("app_install")?["install_type"] as? String, "new", "\(names()) \(String(describing: data("app_install")))")
        XCTAssertEqual(reads.value, 0, "no reclassification")
    }

    func testHostHintIsReadOnce() async throws {
        provide(signals(ranBefore: false))
        let calls = Box(0)
        _ = try await launch(Self.config(hint: { calls.value += 1; return true }))
        XCTAssertEqual(data("$sdk_first_launch_existing")?["detection_method"] as? String, "host_hint")
        _ = try await launch(Self.config(hint: { calls.value += 1; return true }))
        XCTAssertEqual(calls.value, 1)
    }
}
