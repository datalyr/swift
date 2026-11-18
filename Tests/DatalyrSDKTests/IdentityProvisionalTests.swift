import XCTest
@testable import DatalyrSDK

/// Stubs POST /attribution/lookup (the identify(email) web-attribution lookup) for
/// URLSession.shared.
final class EmailLookupStub: URLProtocol {
    private static let lock = NSLock()
    private static var _responses: [[String: Any]] = []
    private static var _count = 0
    private static var _delay: TimeInterval = 0

    static var count: Int { lock.withLock { _count } }
    static var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    static func enqueue(_ body: [String: Any]) { lock.withLock { _responses.append(body) } }
    static func reset() { lock.withLock { _responses = []; _count = 0; _delay = 0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/attribution/lookup"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: [String: Any] = Self.lock.withLock {
            Self._count += 1
            return Self._responses.isEmpty ? ["found": false] : Self._responses.removeFirst()
        }
        let respond = { [self] in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        let delay = Self.delay
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: respond)
        } else {
            respond()
        }
    }
    override func stopLoading() {}
}

/// Ingest (`/track`) that answers 200 after `delay` seconds: an event send in flight.
final class SlowIngestStub: URLProtocol {
    private static let lock = NSLock()
    private static var _delay: TimeInterval = 0
    private static var _started = 0

    static var started: Int { lock.withLock { _started } }
    static var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    static func reset() { lock.withLock { _delay = 0; _started = 0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slow-ingest.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delay: TimeInterval = Self.lock.withLock { Self._started += 1; return Self._delay }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"success":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// 2.1.19 identity fixes, driven through the real SDK: provisional (pre-login) ids,
/// RevenueCat/Superwall attribute re-push, and the web-attribution self-match guard.
final class IdentityProvisionalTests: XCTestCase {

    private final class Box<T> {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private var payloads = Box<[EventPayload]>([])
    private var events = Box<[(String, EventData?)]>([])

    private static let identityKeys = [
        StorageKeys.userId, StorageKeys.userIdProvisional, StorageKeys.userProperties,
        StorageKeys.lastIdentityKey, StorageKeys.anonymousId, StorageKeys.visitorId,
        StorageKeys.attributionData, "datalyr_web_attribution_checked",
    ]

    private static func clearIdentityStorage() async {
        for key in identityKeys { await DatalyrStorage.shared.removeValue(key) }
    }

    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(DeferredLookupStub.self)
        URLProtocol.registerClass(EmailLookupStub.self)
        DeferredLookupStub.reset()
        EmailLookupStub.reset()
        payloads = Box([])
        events = Box([])
        await Self.clearIdentityStorage()
        await ATTDeferredLookupTests.clearLookupStorage()
        await DatalyrStorage.shared.removeValue(StorageKeys.firstLaunchTime)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(DeferredLookupStub.self)
        URLProtocol.unregisterClass(EmailLookupStub.self)
        DeferredLookupStub.reset()
        EmailLookupStub.reset()
        await Self.clearIdentityStorage()
        await ATTDeferredLookupTests.clearLookupStorage()
        try await super.tearDown()
    }

    /// A "launch": fresh SDK over the persisted storage, ids and user state loaded as
    /// initialize() loads them (no event queue, no network besides stubbed lookups).
    private func launch() async -> DatalyrSDK {
        let manager = AttributionManager()
        await manager.initialize()
        let platform = PlatformIntegrationManager()
        platform.attStatusProvider = { 3 }
        let sdk = DatalyrSDK()
        observe(sdk)
        sdk.configureForDeferredLookupTesting(
            config: DatalyrConfig(apiKey: "dk_test"),
            attributionManager: manager,
            platformIntegrationManager: platform
        )
        await sdk.loadIdentityForTesting()
        return sdk
    }

    private func observe(_ sdk: DatalyrSDK) {
        let payloads = self.payloads
        let events = self.events
        sdk.payloadObserverForTesting = { payloads.value.append($0) }
        sdk.trackObserverForTesting = { name, data in events.value.append((name, data)) }
    }

    /// The real initialize(): queue pointed at a closed local port, no auto events, no
    /// attribution lookups.
    private static let initConfig = DatalyrConfig(
        apiKey: "dk_test",
        endpoint: "http://127.0.0.1:9/track",
        maxRetries: 0,
        retryDelay: 0.01,
        timeout: 1,
        flushInterval: 3600,
        enableAutoEvents: false,
        enableAttribution: false
    )

    private func sent(_ name: String) -> [EventPayload] { payloads.value.filter { $0.eventName == name } }
    private let wireClient = DatalyrHTTPClient(
        endpoint: "", config: HTTPClientConfig(apiKey: "k", workspaceId: "ws", useServerTracking: true)
    )
    /// The `properties` object exactly as it goes to ingest.
    private func wireProps(_ p: EventPayload) -> [String: Any] {
        wireClient.transformForServerAPI(p)["properties"] as? [String: Any] ?? [:]
    }
    private func isMarked(_ p: EventPayload) -> Bool { (wireProps(p)["$provisional_user_id"] as? Bool) == true }
    private func hasMarkerKey(_ p: EventPayload) -> Bool { wireProps(p)["$provisional_user_id"] != nil }

    /// Waits until everything queued on the main queue so far has run.
    private func drainMain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }

    // MARK: - Provisional marker

    func testProvisionalIdentifyMarksEveryEventIncludingIdentify() async {
        let sdk = await launch()
        await sdk.track("before_identify")
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.track("onboarding_step")
        await sdk.screen("Home")

        XCTAssertFalse(hasMarkerKey(sent("before_identify")[0]), "no user yet → no marker")
        let identify = sent("$identify")
        XCTAssertEqual(identify.count, 1)
        XCTAssertTrue(isMarked(identify[0]), "$identify of a provisional id carries the marker")
        XCTAssertEqual(identify[0].userId, "guest-uuid-1")
        XCTAssertTrue(isMarked(sent("onboarding_step")[0]))
        XCTAssertTrue(isMarked(sent("pageview")[0]))
        XCTAssertTrue(sdk.currentUserIsProvisionalForTesting)
    }

    func testCallerSuppliedMarkerIsStripped() async {
        let sdk = await launch()
        await sdk.track("anon_claim", eventData: ["$provisional_user_id": true])
        await sdk.identify("account-B")
        await sdk.track("real_claim", eventData: ["$provisional_user_id": true, "keep": 1])
        XCTAssertFalse(hasMarkerKey(sent("anon_claim")[0]), "caller cannot set the marker with no user")
        XCTAssertFalse(hasMarkerKey(sent("real_claim")[0]), "caller cannot mark a signed-in user provisional")
        XCTAssertEqual(wireProps(sent("real_claim")[0])["keep"] as? Int, 1)

        // While provisional the SDK's own value wins (a caller false does not unmark it).
        await sdk.reset()
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.track("guest_event", eventData: ["$provisional_user_id": false])
        XCTAssertTrue(isMarked(sent("guest_event")[0]))
    }

    func testProvisionalStateSurvivesRelaunch() async {
        let first = await launch()
        await first.identify("guest-uuid-1", provisional: true)
        let flag = await DatalyrStorage.shared.getString(StorageKeys.userIdProvisional)
        XCTAssertEqual(flag, DatalyrSDK.provisionalFlag(for: "guest-uuid-1"))
        XCTAssertTrue(flag?.hasPrefix("provisional:") == true)
        XCTAssertFalse(flag?.contains("guest-uuid-1") == true, "flag stores a hash, not the id")

        let second = await launch()
        XCTAssertEqual(second.getStatus().currentUserId, "guest-uuid-1")
        XCTAssertTrue(second.currentUserIsProvisionalForTesting)
        await second.track("relaunch_event")
        XCTAssertTrue(isMarked(sent("relaunch_event")[0]))
    }

    /// Downgrade to ≤ 2.1.18, which signs in B without touching the flag: the flag left for
    /// the guest id must not make B provisional on the next 2.1.19 launch.
    func testFlagForAnotherUserIdIsIgnored() async {
        await DatalyrStorage.shared.setString(StorageKeys.userIdProvisional, value: DatalyrSDK.provisionalFlag(for: "guest-uuid-1"))
        await DatalyrStorage.shared.setString(StorageKeys.userId, value: "account-B")
        let sdk = await launch()
        XCTAssertEqual(sdk.getStatus().currentUserId, "account-B")
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
        await sdk.identify("guest-uuid-1", provisional: true)
        XCTAssertEqual(sdk.getStatus().currentUserId, "account-B", "signed-in B is not overridden")
    }

    /// A bare boolean (the unreleased first 2.1.19 cut) is not a flag for any id.
    func testLegacyBooleanFlagIsNotProvisional() async {
        await DatalyrStorage.shared.setBool(StorageKeys.userIdProvisional, value: true)
        await DatalyrStorage.shared.setString(StorageKeys.userId, value: "account-B")
        let sdk = await launch()
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
    }

    func testRepeatedProvisionalIdentifyIsRedundant() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.identify("guest-uuid-1", provisional: true)
        XCTAssertEqual(sent("$identify").count, 1)
    }

    // MARK: - Real initialize(): pre-init provisional replay, restore, init-end push

    func testInitializeReplaysBufferedProvisionalIdentifyAndPushesAttributes() async throws {
        let sdk = DatalyrSDK()
        observe(sdk)
        let rc = Box<[[String: String]]>([])
        sdk.syncRevenueCatAttributes { rc.value.append($0) }
        await sdk.identify("guest-uuid-1", provisional: true)   // buffered
        await sdk.track("pre_init_event")                       // buffered
        await drainMain()
        XCTAssertTrue(rc.value.isEmpty, "a handler registered before init is not called before init")
        XCTAssertTrue(payloads.value.isEmpty)

        try await sdk.initialize(config: Self.initConfig)
        await drainMain()

        XCTAssertEqual(sent("$identify").count, 1)
        XCTAssertTrue(isMarked(sent("$identify")[0]), "buffered provisional identify replays with the flag")
        XCTAssertTrue(isMarked(sent("pre_init_event")[0]))
        XCTAssertTrue(sdk.currentUserIsProvisionalForTesting)
        XCTAssertEqual(rc.value.count, 1, "initialize() pushes once to a pre-init handler")
        XCTAssertEqual(rc.value.last?["datalyr_id"], sdk.getAnonymousId())

        // Relaunch through initialize(): the persisted flag is restored.
        let relaunched = DatalyrSDK()
        try await relaunched.initialize(config: Self.initConfig)
        XCTAssertEqual(relaunched.getStatus().currentUserId, "guest-uuid-1")
        XCTAssertTrue(relaunched.currentUserIsProvisionalForTesting)
        await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
    }

    // MARK: - Provisional → real: no reset

    func testProvisionalToRealDoesNotResetAndDropsMarker() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        let anonBefore = sdk.getAnonymousId()

        await sdk.identify("firebase-uid-B")

        XCTAssertEqual(sdk.getAnonymousId(), anonBefore, "provisional → real must not run the account-switch reset")
        XCTAssertEqual(sdk.getStatus().currentUserId, "firebase-uid-B")
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
        let identify = sent("$identify")
        XCTAssertEqual(identify.count, 2)
        XCTAssertEqual(identify[1].userId, "firebase-uid-B")
        XCTAssertFalse(hasMarkerKey(identify[1]), "the real $identify carries no marker")
        XCTAssertEqual(wireProps(identify[1])["anonymous_id"] as? String, anonBefore)
        XCTAssertTrue(sent("$alias").isEmpty, "no $alias is sent for a provisional conversion")

        await sdk.track("after_login")
        XCTAssertFalse(hasMarkerKey(sent("after_login")[0]))

        let relaunched = await launch()
        XCTAssertFalse(relaunched.currentUserIsProvisionalForTesting, "real identify clears the persisted flag")
    }

    func testProvisionalToProvisionalDoesNotReset() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        let anonBefore = sdk.getAnonymousId()
        await sdk.identify("guest-uuid-2", provisional: true)

        XCTAssertEqual(sdk.getAnonymousId(), anonBefore)
        XCTAssertEqual(sdk.getStatus().currentUserId, "guest-uuid-2")
        XCTAssertEqual(sent("$identify").count, 2)
        XCTAssertTrue(isMarked(sent("$identify")[1]))
    }

    // MARK: - Real user current: provisional ignored, real switch still resets

    func testProvisionalIgnoredWhileRealUserCurrent() async {
        let sdk = await launch()
        await sdk.identify("firebase-uid-B")
        let anonBefore = sdk.getAnonymousId()

        await sdk.identify("guest-uuid-1", provisional: true)

        XCTAssertEqual(sdk.getStatus().currentUserId, "firebase-uid-B")
        XCTAssertEqual(sdk.getAnonymousId(), anonBefore, "no reset")
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
        XCTAssertEqual(sent("$identify").count, 1, "no $identify for the ignored provisional id")
        await sdk.track("still_real")
        XCTAssertFalse(hasMarkerKey(sent("still_real")[0]))
    }

    func testRealToDifferentRealStillResets() async {
        let sdk = await launch()
        await sdk.identify("account-A")
        let anonBefore = sdk.getAnonymousId()

        await sdk.identify("account-B")

        XCTAssertNotEqual(sdk.getAnonymousId(), anonBefore, "account switch rotates the anonymous id")
        XCTAssertEqual(sdk.getStatus().currentUserId, "account-B")
        let identify = sent("$identify")
        XCTAssertEqual(identify.count, 2)
        XCTAssertEqual(wireProps(identify[1])["anonymous_id"] as? String, sdk.getAnonymousId())
    }

    /// identify(guest, provisional) and identify(account) racing: whatever the order, the
    /// signed-in account wins (guest first → converted; account first → guest ignored).
    func testConcurrentProvisionalAndRealIdentifyNeverLeavesGuest() async {
        for i in 0..<40 {
            await Self.clearIdentityStorage()
            let sdk = await launch()
            async let guest: Void = sdk.identify("guest-\(i)", provisional: true)
            async let account: Void = sdk.identify("account-\(i)")
            _ = await (guest, account)
            XCTAssertEqual(sdk.getStatus().currentUserId, "account-\(i)", "iteration \(i)")
            XCTAssertFalse(sdk.currentUserIsProvisionalForTesting, "iteration \(i)")
        }
    }

    /// reset() racing an account identify: every $identify pairs the user with the
    /// anonymous id that was current when it was built (never a pre-reset id).
    func testConcurrentResetAndIdentifyKeepIdsConsistent() async {
        for i in 0..<20 {
            await Self.clearIdentityStorage()
            payloads = Box([])
            let sdk = await launch()
            await sdk.identify("account-A-\(i)")
            async let r: Void = sdk.reset()
            async let b: Void = sdk.identify("account-B-\(i)")
            _ = await (r, b)
            let last = sent("$identify").last
            XCTAssertEqual(last?.userId, sdk.getStatus().currentUserId ?? last?.userId)
            if sdk.getStatus().currentUserId != nil {
                XCTAssertEqual(last?.anonymousId, sdk.getAnonymousId(), "iteration \(i)")
                XCTAssertEqual(wireProps(last!)["anonymous_id"] as? String, sdk.getAnonymousId(), "iteration \(i)")
            }
        }
    }

    func testResetClearsProvisional() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.reset()

        XCTAssertNil(sdk.getStatus().currentUserId)
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
        await sdk.track("after_reset")
        XCTAssertFalse(hasMarkerKey(sent("after_reset")[0]))
        let stored = await DatalyrStorage.shared.getString(StorageKeys.userIdProvisional)
        XCTAssertNil(stored)

        await sdk.identify("guest-uuid-2", provisional: true)
        XCTAssertTrue(sdk.currentUserIsProvisionalForTesting)
    }

    // MARK: - alias() while provisional

    func testAliasWhileProvisionalActsAsIdentify() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        let anonBefore = sdk.getAnonymousId()
        await sdk.alias("account-B")

        XCTAssertTrue(sent("$alias").isEmpty, "no unguarded $alias from the guest id")
        XCTAssertEqual(sent("$identify").last?.userId, "account-B")
        XCTAssertFalse(hasMarkerKey(sent("$identify").last!))
        XCTAssertEqual(sdk.getAnonymousId(), anonBefore, "no reset")
        XCTAssertEqual(sdk.getStatus().currentUserId, "account-B")
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
    }

    func testAliasWithExplicitPreviousIdStillAliases() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.alias("account-B", previousId: "legacy-id")
        XCTAssertEqual(sent("$alias").count, 1)
        XCTAssertEqual(sent("$alias")[0].eventData?["previous_id"]?.value as? String, "legacy-id")
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
        await sdk.track("after_alias")
        XCTAssertFalse(hasMarkerKey(sent("after_alias")[0]))
    }

    // MARK: - RevenueCat / Superwall attribute sync

    func testSyncHandlersFireOnRegisterResetBindAndATT() async {
        let sdk = await launch()
        let rc = Box<[[String: String]]>([])
        let sw = Box<[[String: String]]>([])
        let offMain = Box<Bool>(false)

        sdk.syncRevenueCatAttributes { attrs in
            if !Thread.isMainThread { offMain.value = true }
            rc.value.append(attrs)
        }
        sdk.syncSuperwallAttributes { attrs in
            if !Thread.isMainThread { offMain.value = true }
            sw.value.append(attrs)
        }
        await drainMain()
        XCTAssertEqual(rc.value.count, 1, "called once after registration")
        XCTAssertEqual(sw.value.count, 1)
        XCTAssertEqual(rc.value[0]["datalyr_id"], sdk.getAnonymousId())
        XCTAssertEqual(sw.value[0]["datalyr_id"], sdk.getAnonymousId())

        let oldAnon = sdk.getAnonymousId()
        await sdk.reset()
        await drainMain()
        XCTAssertEqual(rc.value.count, 2)
        XCTAssertEqual(rc.value.last?["datalyr_id"], sdk.getAnonymousId())
        XCTAssertNotEqual(rc.value.last?["datalyr_id"], oldAnon)
        XCTAssertEqual(sw.value.last?["datalyr_id"], sdk.getAnonymousId())

        // A plain identify changes nothing the providers hold → no push.
        await sdk.identify("account-A")
        await sdk.identify("account-A")
        await drainMain()
        XCTAssertEqual(rc.value.count, 2)

        await sdk.bindProviderIdentity(namespace: "revenuecat", providerUserId: "rc-user-1")
        await drainMain()
        XCTAssertEqual(rc.value.count, 3)
        XCTAssertEqual(sw.value.count, 3)

        await sdk.updateTrackingAuthorization(status: 3)
        await drainMain()
        XCTAssertEqual(rc.value.count, 4)
        XCTAssertEqual(sw.value.last?["att_status"], "authorized")

        XCTAssertFalse(offMain.value, "handlers run on the main thread")
    }

    /// An account switch pushes ONCE (not from the nested reset and again from identify),
    /// with the new id.
    func testAccountSwitchPushesOnce() async {
        let sdk = await launch()
        await sdk.identify("account-A")
        let rc = Box<[[String: String]]>([])
        sdk.syncRevenueCatAttributes { rc.value.append($0) }
        await drainMain()
        XCTAssertEqual(rc.value.count, 1)

        await sdk.identify("account-B")
        await drainMain()
        XCTAssertEqual(rc.value.count, 2, "one push for the switch")
        XCTAssertEqual(rc.value.last?["datalyr_id"], sdk.getAnonymousId())
    }

    /// After a reset, RevenueCat gets "" for the previous user's attribution keys so its
    /// merging setAttributes deletes them.
    func testResetPushClearsPreviousAttributionForRevenueCat() async {
        let sdk = await launch()
        var data = AttributionData()
        data.utmSource = "facebook"
        data.fbclid = "FB_OLD"
        data.campaignId = "C1"
        await sdk.setAttributionData(data)
        let rc = Box<[[String: String]]>([])
        let sw = Box<[[String: String]]>([])
        sdk.syncRevenueCatAttributes { rc.value.append($0) }
        sdk.syncSuperwallAttributes { sw.value.append($0) }
        await drainMain()
        XCTAssertEqual(rc.value.last?["fbclid"], "FB_OLD")

        await sdk.reset()
        await drainMain()
        let after = rc.value.last ?? [:]
        XCTAssertEqual(after["fbclid"], "")
        XCTAssertEqual(after["utm_source"], "")
        XCTAssertEqual(after["$mediaSource"], "")
        XCTAssertEqual(after["campaign_id"], "")
        XCTAssertEqual(after["datalyr_id"], sdk.getAnonymousId())
        XCTAssertNil(sw.value.last?["fbclid"], "Superwall gets no empty values")
    }

    /// Every acquisition key getRevenueCatAttributes can emit is in the clear list.
    func testRevenueCatClearableKeysCoverAllAttributionKeys() async {
        let sdk = await launch()
        var a = AttributionData()
        a.utmSource = "s"; a.utmMedium = "m"; a.utmCampaign = "c"; a.utmTerm = "t"; a.utmContent = "ct"
        a.lyr = "l"; a.fbclid = "f"; a.gclid = "g"; a.ttclid = "tt"; a.wbraid = "w"; a.gbraid = "gb"
        a.network = "n"; a.creativeId = "cr"; a.campaignId = "ci"; a.adsetId = "as"; a.adId = "ad"
        a.placement = "p"; a.siteSourceName = "ss"; a.keyword = "k"
        await sdk.setAttributionData(a)
        let keys = Set(sdk.getRevenueCatAttributes().keys).subtracting(["datalyr_id", "$idfa", "$attConsentStatus"])
        XCTAssertTrue(keys.isSubset(of: Set(DatalyrSDK.revenueCatClearableKeys)),
                      "missing: \(keys.subtracting(DatalyrSDK.revenueCatClearableKeys))")
    }

    func testNewSyncHandlerReplacesPreviousAndNilUnregisters() async {
        let sdk = await launch()
        let first = Box<Int>(0)
        let second = Box<Int>(0)
        sdk.syncRevenueCatAttributes { _ in first.value += 1 }
        sdk.syncRevenueCatAttributes { _ in second.value += 1 }
        await drainMain()
        await sdk.reset()
        await drainMain()
        XCTAssertEqual(first.value, 0, "the handler is resolved at delivery time: a replaced one is never called")
        XCTAssertEqual(second.value, 3)

        sdk.syncRevenueCatAttributes(nil)
        await sdk.reset()
        await drainMain()
        XCTAssertEqual(second.value, 3, "nil unregisters")
    }

    /// Registration never calls the handler inline, even on the main thread.
    func testRegistrationDeliversAsynchronously() async {
        let sdk = await launch()
        let calls = Box<Int>(0)
        let inline: Int = await MainActor.run {
            sdk.syncSuperwallAttributes { _ in calls.value += 1 }
            return calls.value
        }
        XCTAssertEqual(inline, 0)
        await drainMain()
        XCTAssertEqual(calls.value, 1)
    }

    /// Deliveries are built when they run: queued pushes (ATT, then reset) all carry the
    /// CURRENT datalyr_id, never the pre-reset one.
    func testQueuedDeliveriesNeverCarryStaleId() async {
        let sdk = await launch()
        let rc = Box<[[String: String]]>([])
        sdk.syncRevenueCatAttributes { rc.value.append($0) }
        await drainMain()
        let before = rc.value.count
        let blocker = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { _ = blocker.wait(timeout: .now() + 3) } // hold main
        await sdk.updateTrackingAuthorization(status: 3)  // push queued with the old id state
        await sdk.reset()                                 // id rotates, second push queued
        blocker.signal()
        await drainMain()
        let delivered = rc.value.dropFirst(before)
        XCTAssertEqual(delivered.count, 2)
        for attrs in delivered {
            XCTAssertEqual(attrs["datalyr_id"], sdk.getAnonymousId())
        }
    }

    /// An app that blocks the main thread waiting on identify/reset/bind/ATT must not
    /// deadlock: none of them waits for the main thread.
    func testIdentityCallsDoNotWaitForMainThread() async {
        let sdk = await launch()
        sdk.syncRevenueCatAttributes { _ in }
        sdk.syncSuperwallAttributes { _ in }
        await drainMain()

        let mainBlocked = Box<Bool>(false)
        let finished = DispatchSemaphore(value: 0)
        let completedWhileBlocked = Box<Bool>(false)
        DispatchQueue.main.async {
            mainBlocked.value = true
            completedWhileBlocked.value = finished.wait(timeout: .now() + 3) == .success
        }
        while !mainBlocked.value { try? await Task.sleep(nanoseconds: 5_000_000) }

        await sdk.identify("account-A")
        await sdk.identify("account-B")      // account switch → nested reset
        await sdk.reset()
        await sdk.bindProviderIdentity(namespace: "superwall", providerUserId: "sw-1")
        await sdk.updateTrackingAuthorization(status: 3)
        finished.signal()
        await drainMain()
        XCTAssertTrue(completedWhileBlocked.value, "identity calls completed while main was blocked")
    }

    func testSyncHandlerRegisteredBeforeInitIsDeferred() async {
        let sdk = DatalyrSDK()  // not initialized
        let calls = Box<Int>(0)
        sdk.syncRevenueCatAttributes { _ in calls.value += 1 }
        await drainMain()
        XCTAssertEqual(calls.value, 0, "not called before init")
    }

    // MARK: - Self-match guard (compares the WIRE id, anonymousId)

    func testDeferredMatchOnOwnAnonymousIdIsSelfMatch() async {
        let sdk = await launch()
        XCTAssertFalse(sdk.getAnonymousId().isEmpty)
        DeferredLookupStub.enqueue([
            "found": true,
            "attribution": ["visitor_id": sdk.getAnonymousId(), "fbclid": "FB_SELF"],
        ])
        await sdk.runDeferredLookupIfEligible()

        let names = events.value.map { $0.0 }
        XCTAssertFalse(names.contains("$web_attribution_matched"), "own id reflected back is not a web touch")
        let outcome = events.value.first { $0.0 == "$attribution_match" }
        XCTAssertEqual(outcome?.1?["reason"] as? String, "self_match")
        XCTAssertNil(sdk.getAttributionData().fbclid, "self-match is not merged")
    }

    func testDeferredMatchOnOtherVisitorStillMatches() async {
        let sdk = await launch()
        DeferredLookupStub.enqueue([
            "found": true,
            "attribution": ["visitor_id": "web-visitor-123", "fbclid": "FB_WEB"],
        ])
        await sdk.runDeferredLookupIfEligible()

        XCTAssertTrue(events.value.contains { $0.0 == "$web_attribution_matched" })
        let outcome = events.value.first { $0.0 == "$attribution_match" }
        XCTAssertEqual(outcome?.1?["reason"] as? String, "matched")
    }

    func testEmailLookupOnOwnAnonymousIdIsSkipped() async {
        let sdk = await launch()
        EmailLookupStub.enqueue([
            "found": true,
            "attribution": ["visitor_id": sdk.getAnonymousId(), "fbclid": "FB_SELF"],
        ])
        await sdk.identify("user-1", properties: ["email": "self@example.com"])
        XCTAssertEqual(EmailLookupStub.count, 1)
        XCTAssertFalse(events.value.contains { $0.0 == "$web_attribution_matched" })
        XCTAssertNil(sdk.getAttributionData().fbclid)
    }

    func testEmailLookupOnOtherVisitorMergesAndPushes() async {
        let sdk = await launch()
        let rc = Box<[[String: String]]>([])
        sdk.syncRevenueCatAttributes { rc.value.append($0) }
        await drainMain()
        EmailLookupStub.enqueue([
            "found": true,
            "attribution": ["visitor_id": "web-visitor-9", "fbclid": "FB_WEB"],
        ])
        await sdk.identify("user-1", properties: ["email": "web@example.com"])
        XCTAssertTrue(events.value.contains { $0.0 == "$web_attribution_matched" })
        await drainMain()
        XCTAssertEqual(rc.value.count, 2, "web match re-pushes")
        XCTAssertEqual(rc.value.last?["fbclid"], "FB_WEB")
    }

    // MARK: - The identity lock is never held across network I/O

    /// identify() enqueues `$identify` after releasing the identity lock: enqueue awaits the
    /// queue flush (an HTTP send that can take seconds), and a logout reset() must not wait
    /// behind it.
    func testResetDoesNotWaitForIdentifyEventSend() async throws {
        DatalyrHTTPClient.protocolClassesForTesting = [SlowIngestStub.self]
        SlowIngestStub.reset()
        defer {
            DatalyrHTTPClient.protocolClassesForTesting = nil
            SlowIngestStub.reset()
        }
        await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)  // no backlog from other tests
        let sdk = DatalyrSDK()
        observe(sdk)
        let config = DatalyrConfig(
            apiKey: "dk_test",
            endpoint: "https://slow-ingest.test/track",
            maxRetries: 0,
            retryDelay: 0.01,
            timeout: 10,
            flushInterval: 3600,
            enableAutoEvents: false,
            enableAttribution: false
        )
        try await sdk.initialize(config: config)
        await sdk.flush()
        let sendsBefore = SlowIngestStub.started

        SlowIngestStub.delay = 3
        let identifyTask = Task { await sdk.identify("account-A") }
        let deadline = Date().addingTimeInterval(5)
        while SlowIngestStub.started == sendsBefore && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(SlowIngestStub.started, sendsBefore, "the $identify send is in flight")

        let start = Date()
        await sdk.reset()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "reset() waited \(elapsed)s behind an event send")
        XCTAssertNil(sdk.getStatus().currentUserId)
        SlowIngestStub.delay = 0
        await identifyTask.value
        await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
    }

    // MARK: - A web-attribution answer for a previous identity is dropped

    func testEmailLookupAnsweredAfterResetIsDropped() async {
        let sdk = await launch()
        let rc = Box<[[String: String]]>([])
        sdk.syncRevenueCatAttributes { rc.value.append($0) }
        await drainMain()
        EmailLookupStub.delay = 1
        EmailLookupStub.enqueue([
            "found": true,
            "attribution": ["visitor_id": "web-visitor-old", "fbclid": "FB_OLD_USER"],
        ])
        let identifyTask = Task { await sdk.identify("user-old", properties: ["email": "old@example.com"]) }
        let deadline = Date().addingTimeInterval(5)
        while EmailLookupStub.count == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(EmailLookupStub.count, 1, "lookup in flight")

        await sdk.reset()                       // logout while the lookup is pending
        let anonAfterReset = sdk.getAnonymousId()
        await identifyTask.value                // lookup answers now
        await drainMain()

        XCTAssertFalse(events.value.contains { $0.0 == "$web_attribution_matched" },
                       "no bridge event on the new identity")
        XCTAssertNil(sdk.getAttributionData().fbclid, "old user's click id not merged into the new state")
        let checked = await DatalyrStorage.shared.getString("datalyr_web_attribution_checked")
        XCTAssertNil(checked, "checked-marker not rewritten after reset cleared it")
        XCTAssertFalse(rc.value.contains { $0["fbclid"] == "FB_OLD_USER" }, "old click id never pushed")
        XCTAssertEqual(rc.value.last?["datalyr_id"], anonAfterReset)
    }

    // MARK: - Web match: merged before the bridge event's (slow) send, never after a reset

    /// identify(email) matches; the `$web_attribution_matched` send stalls; reset() runs
    /// during the stall. The old user's click id must not survive into the new state, and
    /// the provider's last push carries the new datalyr_id without it.
    func testResetDuringStalledBridgeSendLeavesNoOldClickIds() async throws {
        DatalyrHTTPClient.protocolClassesForTesting = [SlowIngestStub.self]
        SlowIngestStub.reset()
        defer {
            DatalyrHTTPClient.protocolClassesForTesting = nil
            SlowIngestStub.reset()
        }
        await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
        let sdk = DatalyrSDK()
        observe(sdk)
        try await sdk.initialize(config: DatalyrConfig(
            apiKey: "dk_test",
            endpoint: "https://slow-ingest.test/track",
            maxRetries: 0,
            retryDelay: 0.01,
            timeout: 10,
            flushInterval: 3600,
            enableAutoEvents: false,
            enableAttribution: true
        ))
        await sdk.flush()
        let rc = Box<[[String: String]]>([])
        sdk.syncRevenueCatAttributes { rc.value.append($0) }
        await drainMain()

        EmailLookupStub.delay = 0.5
        EmailLookupStub.enqueue([
            "found": true,
            "attribution": ["visitor_id": "web-visitor-old", "fbclid": "FB_OLD_USER"],
        ])
        let identifyTask = Task { await sdk.identify("user-old", properties: ["email": "old@example.com"]) }

        // Lookup in flight → from now on ingest sends stall; the next send is the bridge event.
        var deadline = Date().addingTimeInterval(5)
        while EmailLookupStub.count == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(EmailLookupStub.count, 1)
        let sendsBefore = SlowIngestStub.started
        SlowIngestStub.delay = 3
        deadline = Date().addingTimeInterval(5)
        while SlowIngestStub.started == sendsBefore && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(SlowIngestStub.started, sendsBefore, "bridge event send is stalled")
        XCTAssertTrue(events.value.contains { $0.0 == "$web_attribution_matched" })

        await sdk.reset()                      // logout during the stalled send
        let anonAfterReset = sdk.getAnonymousId()
        SlowIngestStub.delay = 0
        await identifyTask.value
        await drainMain()

        XCTAssertNil(sdk.getAttributionData().fbclid, "old user's click id survived the reset")
        XCTAssertEqual(rc.value.last?["datalyr_id"], anonAfterReset)
        XCTAssertNotEqual(rc.value.last?["fbclid"], "FB_OLD_USER")
        await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
    }

    /// Deferred (IP) lookup answered after a reset: no merge, no bridge event.
    func testDeferredLookupAnsweredAfterResetIsDropped() async {
        let sdk = await launch()
        DeferredLookupStub.delay = 1
        DeferredLookupStub.enqueue([
            "found": true,
            "attribution": ["visitor_id": "web-visitor-old", "fbclid": "FB_OLD_INSTALL"],
        ])
        let lookup = Task { await sdk.runDeferredLookupIfEligible() }
        let deadline = Date().addingTimeInterval(5)
        while DeferredLookupStub.bodies.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(DeferredLookupStub.bodies.count, 1, "lookup in flight")
        await sdk.reset()
        await lookup.value

        XCTAssertNil(sdk.getAttributionData().fbclid)
        XCTAssertFalse(events.value.contains { $0.0 == "$web_attribution_matched" })
    }
}
