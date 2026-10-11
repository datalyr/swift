import XCTest
@testable import DatalyrSDK

/// LinkedIn (`li_fat_id`), Snapchat (`ScCid` → `sclid`), AppLovin (`aleid`, `alart`) and X
/// (`twclid`) click ids: deep-link capture, legacy `li_click_id` migration, the touch
/// `clickIdType` for every id, and the web-attribution match response.
final class AdPlatformClickIdTests: XCTestCase {

    // MARK: - LinkedIn: li_fat_id captured, li_click_id no longer captured

    func testDeepLinkCapturesLiFatId() async {
        let mgr = AttributionManager()
        let params = await mgr.handleDeepLink(URL(string: "myapp://open?li_fat_id=LI_FAT_1&utm_source=linkedin")!)
        XCTAssertEqual(params["li_fat_id"], "LI_FAT_1")

        let data = mgr.getAttributionData()
        XCTAssertEqual(data.liFatId, "LI_FAT_1")
        let wire = data.toDictionary()
        XCTAssertEqual(wire["li_fat_id"] as? String, "LI_FAT_1")
        XCTAssertNil(wire["li_click_id"], "li_click_id is never sent")
    }

    func testDeepLinkNoLongerCapturesLiClickId() async {
        XCTAssertTrue(ATTRIBUTION_PARAMS.contains("li_fat_id"))
        XCTAssertFalse(ATTRIBUTION_PARAMS.contains("li_click_id"), "LinkedIn never sends li_click_id")

        let mgr = AttributionManager()
        let params = await mgr.handleDeepLink(URL(string: "myapp://open?li_click_id=NOPE")!)
        XCTAssertTrue(params.isEmpty)
        XCTAssertNil(mgr.getAttributionData().liFatId)
        XCTAssertNil(mgr.getAttributionData().toDictionary()["li_click_id"])
    }

    /// The old public property still compiles for existing apps and aliases the new field.
    /// (Marked deprecated itself so using the deprecated alias does not warn.)
    @available(*, deprecated)
    func testDeprecatedLiClickIdAliasesLiFatId() {
        var a = AttributionData()
        a.liFatId = "LI"
        XCTAssertEqual(a.liClickId, "LI")
        a.liClickId = "LI_SET"
        XCTAssertEqual(a.liFatId, "LI_SET")
        XCTAssertNil(a.toDictionary()["li_click_id"])
    }

    // MARK: - LinkedIn: a persisted li_click_id survives the upgrade as li_fat_id

    /// JSON as 2.1.16 persisted it (`li_click_id` under its CodingKey).
    private let legacyJSON = #"{"fbclid":"FB_OLD","li_click_id":"LI_OLD","utm_source":"linkedin"}"#

    func testLegacyLiClickIdDecodesAndMigrates() throws {
        var decoded = try JSONDecoder().decode(AttributionData.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.legacyLiClickId, "LI_OLD", "the legacy key must still decode")

        XCTAssertTrue(decoded.migrateLegacyClickIds())
        XCTAssertEqual(decoded.liFatId, "LI_OLD")
        XCTAssertNil(decoded.legacyLiClickId)
        XCTAssertFalse(decoded.migrateLegacyClickIds(), "migration runs once")

        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertEqual(reencoded?["li_fat_id"] as? String, "LI_OLD")
        XCTAssertNil(reencoded?["li_click_id"], "the legacy key is gone after migration")
        XCTAssertEqual(reencoded?["fbclid"] as? String, "FB_OLD", "other fields untouched")
    }

    func testUnmigratedLegacyValueGoesOnTheWireAsLiFatId() throws {
        let decoded = try JSONDecoder().decode(AttributionData.self, from: Data(legacyJSON.utf8))
        let wire = decoded.toDictionary()
        XCTAssertEqual(wire["li_fat_id"] as? String, "LI_OLD")
        XCTAssertNil(wire["li_click_id"])
        XCTAssertEqual(wire["fbclid"] as? String, "FB_OLD")
        XCTAssertEqual(wire["utm_source"] as? String, "linkedin")
    }

    func testExistingLiFatIdWinsOverLegacyValue() throws {
        let json = #"{"li_fat_id":"LI_NEW","li_click_id":"LI_OLD"}"#
        var decoded = try JSONDecoder().decode(AttributionData.self, from: Data(json.utf8))
        decoded.migrateLegacyClickIds()
        XCTAssertEqual(decoded.liFatId, "LI_NEW")
        XCTAssertNil(decoded.legacyLiClickId)
    }

    func testInitializeMigratesPersistedLegacyLiClickId() async {
        var persisted = AttributionData()
        persisted.legacyLiClickId = "LI_PERSISTED"
        persisted.gclid = "GC_PERSISTED"
        await DatalyrStorage.shared.setCodable(StorageKeys.attributionData, value: persisted)

        let mgr = AttributionManager()
        await mgr.initialize()
        XCTAssertEqual(mgr.getAttributionData().liFatId, "LI_PERSISTED")
        XCTAssertNil(mgr.getAttributionData().legacyLiClickId)
        XCTAssertEqual(mgr.getAttributionData().gclid, "GC_PERSISTED")

        // Re-saved, so the next launch reads li_fat_id directly.
        let stored = await DatalyrStorage.shared.getCodable(StorageKeys.attributionData, type: AttributionData.self)
        XCTAssertEqual(stored?.liFatId, "LI_PERSISTED")
        XCTAssertNil(stored?.legacyLiClickId)

        await mgr.clearAttributionData()
    }

    // MARK: - Snapchat: ScCid / sccid / sclid → sclid

    func testDeepLinkCapturesSnapchatScCidAsSclid() async {
        let mgr = AttributionManager()
        await mgr.handleDeepLink(URL(string: "https://app.example.com/p?ScCid=SNAP_1")!)
        XCTAssertEqual(mgr.getAttributionData().sclid, "SNAP_1")
        XCTAssertEqual(mgr.getAttributionData().toDictionary()["sclid"] as? String, "SNAP_1")
    }

    func testDeepLinkCapturesLowercaseSccidAndCanonicalSclid() async {
        let a = AttributionManager()
        await a.handleDeepLink(URL(string: "myapp://open?sccid=SNAP_2")!)
        XCTAssertEqual(a.getAttributionData().sclid, "SNAP_2")

        let b = AttributionManager()
        await b.handleDeepLink(URL(string: "myapp://open?sclid=SNAP_3")!)
        XCTAssertEqual(b.getAttributionData().sclid, "SNAP_3")

        // Snap's own param wins when both are present.
        let c = AttributionManager()
        await c.handleDeepLink(URL(string: "myapp://open?sclid=CANON&ScCid=REAL")!)
        XCTAssertEqual(c.getAttributionData().sclid, "REAL")
    }

    // MARK: - AppLovin: aleid / alart verbatim

    func testDeepLinkCapturesAppLovinIdsVerbatim() async {
        let mgr = AttributionManager()
        // Opaque values: mixed case, dashes, underscores, and an encoded '=' must come back as-is.
        await mgr.handleDeepLink(URL(string: "myapp://open?aleid=AbC-123_xyz%3D%3D&alart=Usr_9-Q")!)
        let data = mgr.getAttributionData()
        XCTAssertEqual(data.aleid, "AbC-123_xyz==")
        XCTAssertEqual(data.alart, "Usr_9-Q")
        let wire = data.toDictionary(includingAppUserIds: true)
        XCTAssertEqual(wire["aleid"] as? String, "AbC-123_xyz==")
        XCTAssertEqual(wire["alart"] as? String, "Usr_9-Q")
    }

    // MARK: - alart rides only app_install / $deep_link

    func testAlartIsNotAttachedToGeneralEvents() {
        var a = AttributionData()
        a.utmSource = "applovin"; a.aleid = "AL"; a.alart = "APP_USER"
        for name in ["purchase", "session_start", "$identify", "$web_attribution_matched", "screen_view", "app_open"] {
            let props = a.eventProperties(for: name)
            XCTAssertNil(props["alart"], "\(name) must not carry alart")
            XCTAssertEqual(props["aleid"] as? String, "AL", "click ids still ride \(name)")
            XCTAssertEqual(props["utm_source"] as? String, "applovin")
        }
        XCTAssertNil(a.toDictionary()["alart"], "the default dictionary excludes app-user ids")
    }

    func testAlartIsAttachedToAppInstallAndDeepLink() {
        var a = AttributionData()
        a.alart = "APP_USER"
        XCTAssertEqual(AttributionData.appUserIdEvents, ["app_install", "$deep_link"])
        XCTAssertEqual(a.eventProperties(for: "app_install")["alart"] as? String, "APP_USER")
        XCTAssertEqual(a.eventProperties(for: "$deep_link")["alart"] as? String, "APP_USER")
    }

    func testWebMatchEventCarriesAlartOnlyFromTheResponse() {
        XCTAssertEqual(webMatchEventIds(lookupResponse(["alart": "FROM_RESPONSE"])), ["alart": "FROM_RESPONSE"])
        XCTAssertNil(webMatchEventIds(lookupResponse([:]))["alart"])
        var stored = AttributionData()
        stored.alart = "STORED"
        XCTAssertNil(stored.eventProperties(for: "$web_attribution_matched")["alart"],
                     "persisted alart is not attached to the match event")
    }

    func testNewIdsRoundTripThroughPersistence() throws {
        var a = AttributionData()
        a.twclid = "tw"; a.liFatId = "li"; a.sclid = "sc"; a.aleid = "al"; a.alart = "ar"
        let decoded = try JSONDecoder().decode(AttributionData.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded.twclid, "tw")
        XCTAssertEqual(decoded.liFatId, "li")
        XCTAssertEqual(decoded.sclid, "sc")
        XCTAssertEqual(decoded.aleid, "al")
        XCTAssertEqual(decoded.alart, "ar")
    }

    // MARK: - clickIdType for every click id

    func testPrimaryClickIdTypeKeepsTheOriginalPrecedence() {
        var a = AttributionData()
        a.fbclid = "f"; a.gclid = "g"; a.ttclid = "t"; a.twclid = "x"; a.aleid = "al"
        XCTAssertEqual(a.primaryClickIdType, "fbclid")
        a.fbclid = nil
        XCTAssertEqual(a.primaryClickIdType, "gclid")
        a.gclid = nil
        XCTAssertEqual(a.primaryClickIdType, "ttclid", "ttclid still outranks every newer id")
        a.ttclid = nil
        XCTAssertEqual(a.primaryClickIdType, "twclid")
    }

    func testPrimaryClickIdTypeIsSetForEveryClickId() {
        let cases: [(WritableKeyPath<AttributionData, String?>, String)] = [
            (\.fbclid, "fbclid"), (\.gclid, "gclid"), (\.ttclid, "ttclid"),
            (\.gbraid, "gbraid"), (\.wbraid, "wbraid"), (\.oppref, "oppref"),
            (\.msclkid, "msclkid"), (\.twclid, "twclid"), (\.liFatId, "li_fat_id"),
            (\.sclid, "sclid"), (\.dclid, "dclid"), (\.aleid, "aleid")
        ]
        for (path, type) in cases {
            var a = AttributionData()
            a[keyPath: path] = "v"
            XCTAssertEqual(a.primaryClickIdType, type)
        }
        var none = AttributionData()
        XCTAssertNil(none.primaryClickIdType)
        none.alart = "app_user"
        XCTAssertNil(none.primaryClickIdType, "alart is an app-user id, not a click id")
    }

    func testNewPlatformOrderFollowsTheWebSdk() {
        var a = AttributionData()
        a.twclid = "x"; a.liFatId = "li"; a.sclid = "sc"; a.aleid = "al"
        XCTAssertEqual(a.primaryClickIdType, "twclid")
        a.twclid = nil
        XCTAssertEqual(a.primaryClickIdType, "li_fat_id")
        a.liFatId = nil
        XCTAssertEqual(a.primaryClickIdType, "sclid")
        a.sclid = nil
        XCTAssertEqual(a.primaryClickIdType, "aleid")
    }

    func testTouchAttributionDecodesTouchesSavedBeforeTheNewFields() throws {
        let old = #"{"timestamp":1,"expiresAt":2,"capturedAt":3,"fbclid":"F","clickIdType":"fbclid"}"#
        let touch = try JSONDecoder().decode(TouchAttribution.self, from: Data(old.utf8))
        XCTAssertEqual(touch.fbclid, "F")
        XCTAssertNil(touch.twclid)
        XCTAssertNil(touch.liFatId)

        var t = TouchAttribution(timestamp: 1, expiresAt: 2, capturedAt: 3)
        t.twclid = "x"; t.liFatId = "li"; t.sclid = "sc"; t.aleid = "al"; t.clickIdType = "twclid"
        let back = try JSONDecoder().decode(TouchAttribution.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.twclid, "x")
        XCTAssertEqual(back.liFatId, "li")
        XCTAssertEqual(back.sclid, "sc")
        XCTAssertEqual(back.aleid, "al")
        XCTAssertEqual(back.clickIdType, "twclid")
    }

    // MARK: - Bare click-id links record a touch (no utm_source seeded)

    func testBareClickIdLinksRecordFirstAndLastTouch() async {
        let cases = ["li_fat_id", "sclid", "twclid", "aleid", "fbclid", "ttclid", "gclid", "msclkid", "oppref"]
        for key in cases {
            let mgr = AttributionManager()
            await mgr.handleDeepLink(URL(string: "myapp://open?\(key)=\(key)_BARE")!)
            let data = mgr.getAttributionData()
            XCTAssertNil(data.utmSource)
            XCTAssertTrue(data.hasJourneyAttribution, "\(key) alone must pass the startup gate")

            let touch = data.makeTouchAttribution(capturedAt: data.attributionCapturedAt ?? 1)
            XCTAssertEqual(touch.clickIdType, key)

            await JourneyManager.shared.clearJourney()
            await JourneyManager.shared.recordAttribution(sessionId: "sess_bare", attribution: touch)
            XCTAssertEqual(JourneyManager.shared.getFirstTouch()?.clickIdType, key, "\(key): first touch")
            XCTAssertEqual(JourneyManager.shared.getLastTouch()?.clickIdType, key, "\(key): last touch")
            XCTAssertNil(JourneyManager.shared.getFirstTouch()?.source)
        }
        let touch = JourneyManager.shared.getLastTouch()
        XCTAssertEqual(touch?.oppref, "oppref_BARE")
        await JourneyManager.shared.clearJourney()
    }

    func testNewIdsAreCopiedOntoTheTouch() {
        var a = AttributionData()
        a.twclid = "x"; a.liFatId = "li"; a.sclid = "sc"; a.aleid = "al"
        let t = a.makeTouchAttribution(capturedAt: 5)
        XCTAssertEqual(t.twclid, "x")
        XCTAssertEqual(t.liFatId, "li")
        XCTAssertEqual(t.sclid, "sc")
        XCTAssertEqual(t.aleid, "al")
        XCTAssertEqual(t.clickIdType, "twclid")
        XCTAssertEqual(t.capturedAt, 5)
    }

    func testAlartOnlyRecordsNoTouch() {
        var a = AttributionData()
        a.alart = "app_user"
        XCTAssertFalse(a.hasJourneyAttribution, "alart is an app-user id, not a click")
        var withUtm = AttributionData()
        withUtm.utmSource = "newsletter"
        XCTAssertTrue(withUtm.hasJourneyAttribution, "the utm_source leg is unchanged")
    }

    func testJourneyGateAcceptsClickIdOnlyTouchWithoutClickIdType() async {
        // Public recordAttribution: a caller passing only fbclid (no clickIdType, no source)
        // was dropped because the gate checked the never-set `clickId`.
        var t = TouchAttribution(timestamp: 1, expiresAt: 0, capturedAt: 1)
        t.fbclid = "FB_ONLY"
        await JourneyManager.shared.clearJourney()
        await JourneyManager.shared.recordAttribution(sessionId: "s", attribution: t)
        XCTAssertEqual(JourneyManager.shared.getFirstTouch()?.fbclid, "FB_ONLY")

        var none = TouchAttribution(timestamp: 1, expiresAt: 0, capturedAt: 1)
        none.medium = "only_medium"
        await JourneyManager.shared.clearJourney()
        await JourneyManager.shared.recordAttribution(sessionId: "s", attribution: none)
        XCTAssertNil(JourneyManager.shared.getFirstTouch(), "no source/click/campaign/lyr → nothing recorded")
        await JourneyManager.shared.clearJourney()
    }

    // MARK: - Empty URL values are dropped

    func testEmptyValueIsNotCaptured() async {
        let mgr = AttributionManager()
        let params = await mgr.handleDeepLink(URL(string: "myapp://open?sclid=&fbclid=&gclid=G1")!)
        XCTAssertEqual(params, ["gclid": "G1"])
        XCTAssertNil(mgr.getAttributionData().sclid)
        XCTAssertNil(mgr.getAttributionData().fbclid)
        XCTAssertEqual(mgr.getAttributionData().primaryClickIdType, "gclid", "an empty fbclid no longer wins")
    }

    func testEmptyValueDoesNotOverwriteAStoredId() async {
        let mgr = AttributionManager()
        await mgr.handleDeepLink(URL(string: "myapp://open?sclid=REAL")!)
        let params = await mgr.handleDeepLink(URL(string: "myapp://open?sclid=#sclid=")!)
        XCTAssertTrue(params.isEmpty)
        XCTAssertEqual(mgr.getAttributionData().sclid, "REAL")
    }

    // MARK: - Web-attribution match response

    /// The API's lookup answer, as `formatAttributionResponse` shapes it: absent ids are `null`.
    private func lookupResponse(_ ids: [String: Any]) -> [String: Any] {
        var r: [String: Any] = [
            "visitor_id": "web_v1", "fbclid": NSNull(), "gclid": NSNull(), "ttclid": NSNull(),
            "twclid": NSNull(), "li_fat_id": NSNull(), "sclid": NSNull(), "utm_source": "linkedin"
        ]
        for (k, v) in ids { r[k] = v }
        return r
    }

    func testMergeWebAttributionFillsTwclidLiFatIdSclidAleid() async {
        let mgr = AttributionManager()
        await mgr.mergeWebAttribution(lookupResponse([
            "twclid": "TW_W", "li_fat_id": "LI_W", "sclid": "SC_W", "aleid": "AL_W"
        ]))
        let data = mgr.getAttributionData()
        XCTAssertEqual(data.twclid, "TW_W")
        XCTAssertEqual(data.liFatId, "LI_W")
        XCTAssertEqual(data.sclid, "SC_W")
        XCTAssertEqual(data.aleid, "AL_W")
        // Attached to every later event like fbclid/gclid/ttclid.
        let wire = data.toDictionary()
        XCTAssertEqual(wire["twclid"] as? String, "TW_W")
        XCTAssertEqual(wire["li_fat_id"] as? String, "LI_W")
        XCTAssertEqual(wire["sclid"] as? String, "SC_W")
        XCTAssertEqual(wire["aleid"] as? String, "AL_W")
        XCTAssertNil(data.fbclid, "a null id in the response is not merged")
    }

    func testMergeWebAttributionDoesNotOverwriteDeviceIds() async {
        let mgr = AttributionManager()
        await mgr.handleDeepLink(URL(string: "myapp://open?twclid=TW_DEVICE&li_fat_id=LI_DEVICE")!)
        await mgr.mergeWebAttribution(lookupResponse(["twclid": "TW_WEB", "li_fat_id": "LI_WEB", "sclid": "SC_WEB"]))
        let data = mgr.getAttributionData()
        XCTAssertEqual(data.twclid, "TW_DEVICE")
        XCTAssertEqual(data.liFatId, "LI_DEVICE")
        XCTAssertEqual(data.sclid, "SC_WEB", "an empty slot is still filled")
    }

    func testMergeWebAttributionIgnoresEmptyAndNullIds() async {
        let mgr = AttributionManager()
        await mgr.mergeWebAttribution(lookupResponse(["twclid": "", "aleid": NSNull()]))
        XCTAssertNil(mgr.getAttributionData().twclid)
        XCTAssertNil(mgr.getAttributionData().aleid)
        XCTAssertNil(mgr.getAttributionData().liFatId)
    }

    func testWebMatchEventPropertiesCarryOnlyPresentIds() {
        XCTAssertEqual(WEB_MATCH_PLATFORM_CLICK_IDS, ["twclid", "li_fat_id", "sclid", "aleid"])
        let props = webMatchEventIds(lookupResponse(["twclid": "TW", "sclid": "", "aleid": "AL"]))
        XCTAssertEqual(props, ["twclid": "TW", "aleid": "AL"])
        XCTAssertTrue(webMatchEventIds(lookupResponse([:])).isEmpty, "null ids add no keys")
    }
}
