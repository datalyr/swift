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
        let metaError = DatalyrPlatformError.metaEventFailed(eventName: "purchase", underlyingError: nil)
        XCTAssertTrue(metaError.description.contains("Meta"))
        XCTAssertTrue(metaError.description.contains("purchase"))
        XCTAssertEqual(metaError.platform, "Meta")

        let tiktokError = DatalyrPlatformError.tiktokEventFailed(eventName: "add_to_cart", underlyingError: nil)
        XCTAssertTrue(tiktokError.description.contains("TikTok"))
        XCTAssertTrue(tiktokError.description.contains("add_to_cart"))
        XCTAssertEqual(tiktokError.platform, "TikTok")

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
        var touch = TouchAttribution()
        touch.sessionId = "sess_123"
        touch.timestamp = "2024-01-15T10:30:00Z"
        touch.source = "google"
        touch.medium = "cpc"
        touch.campaign = "winter_sale"
        touch.fbclid = nil
        touch.gclid = "google_click_456"
        touch.ttclid = nil
        touch.lyr = nil
        touch.clickIdType = "gclid"

        XCTAssertEqual(touch.sessionId, "sess_123")
        XCTAssertEqual(touch.source, "google")
        XCTAssertEqual(touch.medium, "cpc")
        XCTAssertEqual(touch.campaign, "winter_sale")
        XCTAssertNil(touch.fbclid)
        XCTAssertEqual(touch.gclid, "google_click_456")
        XCTAssertNil(touch.ttclid)
        XCTAssertEqual(touch.clickIdType, "gclid")
    }

    // MARK: - Journey Data Tests

    func testJourneyDataCreation() {
        var firstTouch = TouchAttribution()
        firstTouch.sessionId = "sess_1"
        firstTouch.source = "facebook"
        firstTouch.clickIdType = "fbclid"

        var lastTouch = TouchAttribution()
        lastTouch.sessionId = "sess_5"
        lastTouch.source = "google"
        lastTouch.clickIdType = "gclid"

        let journeyData = JourneyData(
            firstTouch: firstTouch,
            lastTouch: lastTouch,
            touchPoints: [firstTouch, lastTouch],
            totalTouchPoints: 5
        )

        XCTAssertEqual(journeyData.firstTouch?.source, "facebook")
        XCTAssertEqual(journeyData.lastTouch?.source, "google")
        XCTAssertEqual(journeyData.touchPoints.count, 2)
        XCTAssertEqual(journeyData.totalTouchPoints, 5)
    }

    // MARK: - Journey Summary Tests

    func testJourneySummaryCreation() {
        let summary = JourneySummary(
            totalTouchPoints: 10,
            uniqueSources: 3,
            hasFirstTouch: true,
            hasLastTouch: true,
            daysSinceFirstTouch: 30,
            daysSinceLastTouch: 2,
            primaryClickIdType: "fbclid"
        )

        XCTAssertEqual(summary.totalTouchPoints, 10)
        XCTAssertEqual(summary.uniqueSources, 3)
        XCTAssertTrue(summary.hasFirstTouch)
        XCTAssertTrue(summary.hasLastTouch)
        XCTAssertEqual(summary.daysSinceFirstTouch, 30)
        XCTAssertEqual(summary.daysSinceLastTouch, 2)
        XCTAssertEqual(summary.primaryClickIdType, "fbclid")
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
}
