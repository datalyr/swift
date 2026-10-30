import XCTest
@testable import DatalyrSDK

/// 2.1.19 identity fixes, driven through the real SDK on an isolated instance (no event
/// queue): provisional (pre-login) ids, RevenueCat/Superwall attribute re-push, and the
/// web-attribution self-match guard.
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
    ]

    private static func clearIdentityStorage() async {
        for key in identityKeys { await DatalyrStorage.shared.removeValue(key) }
    }

    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(DeferredLookupStub.self)
        DeferredLookupStub.reset()
        payloads = Box([])
        events = Box([])
        await Self.clearIdentityStorage()
        await ATTDeferredLookupTests.clearLookupStorage()
        await DatalyrStorage.shared.removeValue(StorageKeys.firstLaunchTime)
        await DatalyrStorage.shared.removeValue(StorageKeys.attributionData)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(DeferredLookupStub.self)
        DeferredLookupStub.reset()
        await Self.clearIdentityStorage()
        await ATTDeferredLookupTests.clearLookupStorage()
        await DatalyrStorage.shared.removeValue(StorageKeys.attributionData)
        try await super.tearDown()
    }

    /// A "launch": fresh SDK over the persisted storage, ids and user state loaded as
    /// initialize() loads them.
    private func launch() async -> DatalyrSDK {
        let manager = AttributionManager()
        await manager.initialize()
        let platform = PlatformIntegrationManager()
        platform.attStatusProvider = { 3 }
        let sdk = DatalyrSDK()
        let payloads = self.payloads
        let events = self.events
        sdk.payloadObserverForTesting = { payloads.value.append($0) }
        sdk.trackObserverForTesting = { name, data in events.value.append((name, data)) }
        sdk.configureForDeferredLookupTesting(
            config: DatalyrConfig(apiKey: "dk_test"),
            attributionManager: manager,
            platformIntegrationManager: platform
        )
        await sdk.loadIdentityForTesting()
        return sdk
    }

    private func sent(_ name: String) -> [EventPayload] { payloads.value.filter { $0.eventName == name } }
    private let wireClient = DatalyrHTTPClient(
        endpoint: "", config: HTTPClientConfig(apiKey: "k", workspaceId: "ws", useServerTracking: true)
    )
    /// The `properties` object exactly as it goes to ingest.
    private func wireProps(_ p: EventPayload) -> [String: Any] {
        wireClient.transformForServerAPI(p)["properties"] as? [String: Any] ?? [:]
    }
    private func isMarked(_ p: EventPayload) -> Bool { (wireProps(p)["$provisional_user_id"] as? Bool) == true }

    // MARK: - Provisional marker

    func testProvisionalIdentifyMarksEveryEventIncludingIdentify() async {
        let sdk = await launch()
        await sdk.track("before_identify")
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.track("onboarding_step")
        await sdk.screen("Home")

        XCTAssertFalse(isMarked(sent("before_identify")[0]), "no user yet → no marker")
        let identify = sent("$identify")
        XCTAssertEqual(identify.count, 1)
        XCTAssertTrue(isMarked(identify[0]), "$identify of a provisional id carries the marker")
        XCTAssertEqual(identify[0].userId, "guest-uuid-1")
        XCTAssertTrue(isMarked(sent("onboarding_step")[0]))
        XCTAssertTrue(isMarked(sent("pageview")[0]))
        XCTAssertTrue(sdk.currentUserIsProvisionalForTesting)
    }

    func testProvisionalStateSurvivesRelaunch() async {
        let first = await launch()
        await first.identify("guest-uuid-1", provisional: true)

        let second = await launch()
        XCTAssertEqual(second.getStatus().currentUserId, "guest-uuid-1")
        XCTAssertTrue(second.currentUserIsProvisionalForTesting)
        await second.track("relaunch_event")
        XCTAssertTrue(isMarked(sent("relaunch_event")[0]))
    }

    func testRepeatedProvisionalIdentifyIsRedundant() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.identify("guest-uuid-1", provisional: true)
        XCTAssertEqual(sent("$identify").count, 1)
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
        XCTAssertFalse(isMarked(identify[1]), "the real $identify carries no marker")
        XCTAssertEqual(wireProps(identify[1])["anonymous_id"] as? String, anonBefore)
        XCTAssertTrue(sent("$alias").isEmpty, "no $alias is sent for a provisional conversion")

        await sdk.track("after_login")
        XCTAssertFalse(isMarked(sent("after_login")[0]))

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
        XCTAssertFalse(isMarked(sent("still_real")[0]))
    }

    func testRealToDifferentRealStillResets() async {
        let sdk = await launch()
        await sdk.identify("account-A")
        let anonBefore = sdk.getAnonymousId()

        await sdk.identify("account-B")

        XCTAssertNotEqual(sdk.getAnonymousId(), anonBefore, "account switch rotates the anonymous id")
        XCTAssertEqual(sdk.getStatus().currentUserId, "account-B")
        XCTAssertEqual(sent("$identify").count, 2)
    }

    func testResetClearsProvisional() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.reset()

        XCTAssertNil(sdk.getStatus().currentUserId)
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
        await sdk.track("after_reset")
        XCTAssertFalse(isMarked(sent("after_reset")[0]))
        let stored = await DatalyrStorage.shared.getBool(StorageKeys.userIdProvisional)
        XCTAssertNil(stored)

        // After reset a real identify is a plain identify; a provisional one is accepted again.
        await sdk.identify("guest-uuid-2", provisional: true)
        XCTAssertTrue(sdk.currentUserIsProvisionalForTesting)
    }

    func testAliasEndsProvisionalState() async {
        let sdk = await launch()
        await sdk.identify("guest-uuid-1", provisional: true)
        await sdk.alias("account-B")
        XCTAssertFalse(sdk.currentUserIsProvisionalForTesting)
        await sdk.track("after_alias")
        XCTAssertFalse(isMarked(sent("after_alias")[0]))
    }

    // MARK: - RevenueCat / Superwall attribute sync

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSyncHandlersFireOnRegisterResetIdentifyAndBind() async {
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
        await waitUntil { rc.value.count == 1 && sw.value.count == 1 }
        XCTAssertEqual(rc.value.count, 1, "called on registration")
        XCTAssertEqual(sw.value.count, 1)
        XCTAssertEqual(rc.value[0]["datalyr_id"], sdk.getAnonymousId())
        XCTAssertEqual(sw.value[0]["datalyr_id"], sdk.getAnonymousId())

        // reset() → new datalyr_id pushed before reset returns.
        let oldAnon = sdk.getAnonymousId()
        await sdk.reset()
        XCTAssertEqual(rc.value.count, 2)
        XCTAssertEqual(rc.value.last?["datalyr_id"], sdk.getAnonymousId())
        XCTAssertNotEqual(rc.value.last?["datalyr_id"], oldAnon)
        XCTAssertEqual(sw.value.last?["datalyr_id"], sdk.getAnonymousId())

        // Non-redundant identify → pushed; redundant → not.
        await sdk.identify("account-A")
        XCTAssertEqual(rc.value.count, 3)
        await sdk.identify("account-A")
        XCTAssertEqual(rc.value.count, 3, "a redundant identify does not re-push")

        // Account switch: the reset inside identify pushes the new id, then identify pushes again.
        await sdk.identify("account-B")
        XCTAssertEqual(rc.value.count, 5)
        XCTAssertEqual(rc.value.last?["datalyr_id"], sdk.getAnonymousId())

        // bindProviderIdentity → pushed.
        await sdk.bindProviderIdentity(namespace: "revenuecat", providerUserId: "rc-user-1")
        XCTAssertEqual(rc.value.count, 6)
        XCTAssertEqual(sw.value.count, 6)

        // ATT answer → idfa / att_status re-pushed.
        await sdk.updateTrackingAuthorization(status: 3)
        XCTAssertEqual(rc.value.count, 7)
        XCTAssertEqual(sw.value.last?["att_status"], "authorized")

        XCTAssertFalse(offMain.value, "handlers run on the main thread")
    }

    func testNewSyncHandlerReplacesPrevious() async {
        let sdk = await launch()
        let first = Box<Int>(0)
        let second = Box<Int>(0)
        sdk.syncRevenueCatAttributes { _ in first.value += 1 }
        sdk.syncRevenueCatAttributes { _ in second.value += 1 }
        await waitUntil { first.value == 1 && second.value == 1 }
        await sdk.reset()
        XCTAssertEqual(first.value, 1, "replaced handler is not called again")
        XCTAssertEqual(second.value, 2)
    }

    func testSyncHandlerRegisteredBeforeInitIsDeferred() async {
        let sdk = DatalyrSDK()  // not initialized
        let calls = Box<Int>(0)
        sdk.syncRevenueCatAttributes { _ in calls.value += 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(calls.value, 0, "not called before init")
        await sdk.notifyAttributeSyncHandlers()
        XCTAssertEqual(calls.value, 0, "notify is a no-op before init")
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
}
