import XCTest
@testable import DatalyrSDK

final class AttributionTests: XCTestCase {

    // MARK: - Attribution Data Tests

    func testAttributionDataCreation() {
        var attribution = AttributionData()

        // Test UTM parameters
        attribution.utmSource = "google"
        attribution.utmMedium = "cpc"
        attribution.utmCampaign = "summer_sale"
        attribution.utmTerm = "running shoes"
        attribution.utmContent = "banner_ad"

        XCTAssertEqual(attribution.utmSource, "google")
        XCTAssertEqual(attribution.utmMedium, "cpc")
        XCTAssertEqual(attribution.utmCampaign, "summer_sale")
        XCTAssertEqual(attribution.utmTerm, "running shoes")
        XCTAssertEqual(attribution.utmContent, "banner_ad")
    }

    func testAttributionDataClickIds() {
        var attribution = AttributionData()

        // Test platform click IDs
        attribution.fbclid = "fb_click_123"
        attribution.gclid = "google_click_456"
        attribution.ttclid = "tiktok_click_789"
        attribution.twclid = "twitter_click_012"
        attribution.liClickId = "linkedin_click_345"
        attribution.msclkid = "microsoft_click_678"

        XCTAssertEqual(attribution.fbclid, "fb_click_123")
        XCTAssertEqual(attribution.gclid, "google_click_456")
        XCTAssertEqual(attribution.ttclid, "tiktok_click_789")
        XCTAssertEqual(attribution.twclid, "twitter_click_012")
        XCTAssertEqual(attribution.liClickId, "linkedin_click_345")
        XCTAssertEqual(attribution.msclkid, "microsoft_click_678")
    }

    func testAttributionDataDatalyrSystem() {
        var attribution = AttributionData()

        // Test Datalyr LYR system
        attribution.lyr = "lyr_campaign_123"
        attribution.datalyr = "datalyr_tag_456"
        attribution.dlTag = "dl_tag_789"
        attribution.dlCampaign = "dl_campaign_012"

        XCTAssertEqual(attribution.lyr, "lyr_campaign_123")
        XCTAssertEqual(attribution.datalyr, "datalyr_tag_456")
        XCTAssertEqual(attribution.dlTag, "dl_tag_789")
        XCTAssertEqual(attribution.dlCampaign, "dl_campaign_012")
    }

    func testAttributionDataCodable() throws {
        var attribution = AttributionData()
        attribution.utmSource = "test_source"
        attribution.utmMedium = "test_medium"
        attribution.fbclid = "test_fbclid"
        attribution.lyr = "test_lyr"

        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(attribution)

        // Decode from JSON
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AttributionData.self, from: data)

        XCTAssertEqual(decoded.utmSource, "test_source")
        XCTAssertEqual(decoded.utmMedium, "test_medium")
        XCTAssertEqual(decoded.fbclid, "test_fbclid")
        XCTAssertEqual(decoded.lyr, "test_lyr")
    }

    // MARK: - Deferred Deep Link Result Tests

    func testDeferredDeepLinkResult() {
        let result = DeferredDeepLinkResult(
            url: "https://app.example.com/product/123",
            source: "meta",
            fbclid: "fb_123",
            ttclid: nil,
            utmSource: "facebook",
            utmMedium: "paid_social",
            utmCampaign: "retargeting",
            utmContent: "carousel",
            utmTerm: nil,
            campaignId: "camp_456",
            adsetId: "adset_789",
            adId: "ad_012"
        )

        XCTAssertEqual(result.url, "https://app.example.com/product/123")
        XCTAssertEqual(result.source, "meta")
        XCTAssertEqual(result.fbclid, "fb_123")
        XCTAssertNil(result.ttclid)
        XCTAssertEqual(result.utmSource, "facebook")
        XCTAssertEqual(result.utmMedium, "paid_social")
        XCTAssertEqual(result.utmCampaign, "retargeting")
        XCTAssertEqual(result.utmContent, "carousel")
        XCTAssertNil(result.utmTerm)
        XCTAssertEqual(result.campaignId, "camp_456")
        XCTAssertEqual(result.adsetId, "adset_789")
        XCTAssertEqual(result.adId, "ad_012")
    }

    // MARK: - Device Info Tests

    func testDeviceInfoCreation() {
        let deviceInfo = DeviceInfo(
            model: "iPhone 15 Pro",
            manufacturer: "Apple",
            osVersion: "17.4",
            screenSize: "1179x2556",
            timezone: "America/Los_Angeles",
            locale: "en_US",
            carrier: "Verizon",
            isEmulator: false
        )

        XCTAssertEqual(deviceInfo.model, "iPhone 15 Pro")
        XCTAssertEqual(deviceInfo.manufacturer, "Apple")
        XCTAssertEqual(deviceInfo.osVersion, "17.4")
        XCTAssertEqual(deviceInfo.screenSize, "1179x2556")
        XCTAssertEqual(deviceInfo.timezone, "America/Los_Angeles")
        XCTAssertEqual(deviceInfo.locale, "en_US")
        XCTAssertEqual(deviceInfo.carrier, "Verizon")
        XCTAssertFalse(deviceInfo.isEmulator)
    }

    func testDeviceInfoCodable() throws {
        let deviceInfo = DeviceInfo(
            model: "iPhone 15",
            manufacturer: "Apple",
            osVersion: "17.0",
            screenSize: "1170x2532",
            timezone: "UTC"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(deviceInfo)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DeviceInfo.self, from: data)

        XCTAssertEqual(decoded.model, "iPhone 15")
        XCTAssertEqual(decoded.manufacturer, "Apple")
        XCTAssertEqual(decoded.osVersion, "17.0")
    }

    // MARK: - SDK Delegate Tests

    func testDatalyrPlatformErrorDescriptions() {
        let skadError = DatalyrPlatformError.skadnetworkUpdateFailed(underlyingError: nil)
        XCTAssertTrue(skadError.description.contains("SKAdNetwork"))
        XCTAssertEqual(skadError.platform, "SKAdNetwork")

        let attributionError = DatalyrPlatformError.attributionFetchFailed(platform: "Apple Search Ads", underlyingError: nil)
        XCTAssertTrue(attributionError.description.contains("Apple Search Ads"))
        XCTAssertEqual(attributionError.platform, "Apple Search Ads")

        let networkError = DatalyrPlatformError.networkError(underlyingError: URLError(.notConnectedToInternet))
        XCTAssertTrue(networkError.description.contains("Network"))
        XCTAssertEqual(networkError.platform, "Network")

        let configError = DatalyrPlatformError.configurationError(message: "Missing API key")
        XCTAssertTrue(configError.description.contains("Missing API key"))
        XCTAssertEqual(configError.platform, "Configuration")
    }

    // MARK: - Touch Attribution Tests

    func testTouchAttributionCreation() {
        // TouchAttribution timestamps are epoch-ms TimeIntervals (matches the 90-day window math).
        let nowMs = Date().timeIntervalSince1970 * 1000
        var touch = TouchAttribution(
            timestamp: nowMs,
            expiresAt: nowMs + 90 * 24 * 60 * 60 * 1000,
            capturedAt: nowMs
        )
        touch.source = "google"
        touch.medium = "cpc"
        touch.campaign = "winter_sale"
        touch.gclid = "google_click_456"
        touch.clickIdType = "gclid"

        XCTAssertEqual(touch.source, "google")
        XCTAssertEqual(touch.medium, "cpc")
        XCTAssertEqual(touch.campaign, "winter_sale")
        XCTAssertNil(touch.fbclid)
        XCTAssertEqual(touch.gclid, "google_click_456")
        XCTAssertNil(touch.ttclid)
        XCTAssertEqual(touch.clickIdType, "gclid")

        // Codable round-trip — JourneyManager persists/loads TouchAttribution via storage.
        let data = try! JSONEncoder().encode(touch)
        let decoded = try! JSONDecoder().decode(TouchAttribution.self, from: data)
        XCTAssertEqual(decoded.source, "google")
        XCTAssertEqual(decoded.gclid, "google_click_456")
        XCTAssertEqual(decoded.timestamp, nowMs)
    }

    // MARK: - Journey Data Tests

    func testTouchPointCreation() {
        // The journey is stored as [TouchPoint]; JourneyData was removed in the model redesign.
        let nowMs = Date().timeIntervalSince1970 * 1000
        let touchPoint = TouchPoint(
            timestamp: nowMs,
            sessionId: "sess_1",
            source: "facebook",
            medium: "social",
            campaign: "launch",
            clickIdType: "fbclid"
        )

        XCTAssertEqual(touchPoint.sessionId, "sess_1")
        XCTAssertEqual(touchPoint.source, "facebook")
        XCTAssertEqual(touchPoint.campaign, "launch")
        XCTAssertEqual(touchPoint.clickIdType, "fbclid")

        // Codable round-trip — the journey array is persisted/loaded as [TouchPoint].
        let data = try! JSONEncoder().encode(touchPoint)
        let decoded = try! JSONDecoder().decode(TouchPoint.self, from: data)
        XCTAssertEqual(decoded.sessionId, "sess_1")
        XCTAssertEqual(decoded.source, "facebook")
    }

    // MARK: - Journey Summary Tests

    func testJourneySummaryCreation() {
        let summary = JourneySummary(
            hasFirstTouch: true,
            hasLastTouch: true,
            touchpointCount: 10,
            daysSinceFirstTouch: 30,
            sources: ["facebook", "google", "tiktok"]
        )

        XCTAssertTrue(summary.hasFirstTouch)
        XCTAssertTrue(summary.hasLastTouch)
        XCTAssertEqual(summary.touchpointCount, 10)
        XCTAssertEqual(summary.daysSinceFirstTouch, 30)
        XCTAssertEqual(summary.sources.count, 3)
        XCTAssertTrue(summary.sources.contains("facebook"))
    }

    // MARK: - Deep Link Click-ID Capture

    func testDeepLinkCapturesGoogleIOSClickIds() async {
        // Regression: gbraid/wbraid (Google's iOS click-ids, sent in place of gclid under
        // ATT/ITP) were listed in ATTRIBUTION_PARAMS and read by getRevenueCatAttributes()
        // but never assigned in processAttributionParameters, so Google App-campaign
        // attribution was silently dropped on every deep link.
        let manager = AttributionManager()
        let url = URL(string: "myapp://open?gbraid=GB_123&wbraid=WB_456&gclid=GC_789&utm_source=google&fbclid=FB_1")!
        await manager.handleDeepLink(url)

        let data = manager.getAttributionData()
        XCTAssertEqual(data.gbraid, "GB_123", "gbraid must be captured from the deep link")
        XCTAssertEqual(data.wbraid, "WB_456", "wbraid must be captured from the deep link")
        XCTAssertEqual(data.gclid, "GC_789")
        XCTAssertEqual(data.fbclid, "FB_1")
        XCTAssertEqual(data.utmSource, "google")
    }

    // MARK: - Performance Tests

    func testAttributionDataEncodingPerformance() {
        var attribution = AttributionData()
        attribution.utmSource = "google"
        attribution.utmMedium = "cpc"
        attribution.utmCampaign = "test_campaign"
        attribution.fbclid = "fb_click_123"
        attribution.gclid = "google_click_456"
        attribution.lyr = "lyr_tag_789"

        let encoder = JSONEncoder()

        measure {
            for _ in 0..<1000 {
                _ = try? encoder.encode(attribution)
            }
        }
    }

    // MARK: - TR-17: handleDeepLink returns the extracted params (so a $deep_link event fires)

    func testTR17_handleDeepLinkReturnsExtractedClickIdsAndLyr() async {
        let mgr = AttributionManager()
        let url = URL(string: "https://app.datalyr.com/promo?fbclid=FB_123&gclid=G_456&lyr=L_789&noise=x")!
        let params = await mgr.handleDeepLink(url)
        XCTAssertEqual(params["fbclid"], "FB_123")
        XCTAssertEqual(params["gclid"], "G_456")
        XCTAssertEqual(params["lyr"], "L_789")
        XCTAssertNil(params["noise"], "non-attribution params are filtered out")
    }

    func testTR17_handleDeepLinkReturnsEmptyWhenNoAttributionParams() async {
        let mgr = AttributionManager()
        let params = await mgr.handleDeepLink(URL(string: "https://app.datalyr.com/home")!)
        XCTAssertTrue(params.isEmpty, "no attributable params → empty return → no $deep_link event")
    }
}
