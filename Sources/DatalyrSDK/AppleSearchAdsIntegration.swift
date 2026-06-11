import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Apple Search Ads Attribution Data
public struct AppleSearchAdsAttribution: Codable {
    public let attribution: Bool
    public let orgId: Int?
    public let orgName: String?
    public let campaignId: Int?
    public let campaignName: String?
    public let adGroupId: Int?
    public let adGroupName: String?
    public let conversionType: String?
    public let clickDate: String?
    public let keyword: String?
    public let keywordId: Int?
    public let region: String?

    public init(
        attribution: Bool = false,
        orgId: Int? = nil,
        orgName: String? = nil,
        campaignId: Int? = nil,
        campaignName: String? = nil,
        adGroupId: Int? = nil,
        adGroupName: String? = nil,
        conversionType: String? = nil,
        clickDate: String? = nil,
        keyword: String? = nil,
        keywordId: Int? = nil,
        region: String? = nil
    ) {
        self.attribution = attribution
        self.orgId = orgId
        self.orgName = orgName
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.adGroupId = adGroupId
        self.adGroupName = adGroupName
        self.conversionType = conversionType
        self.clickDate = clickDate
        self.keyword = keyword
        self.keywordId = keywordId
        self.region = region
    }

    enum CodingKeys: String, CodingKey {
        case attribution
        case orgId
        case orgName
        case campaignId
        case campaignName
        case adGroupId
        case adGroupName
        case conversionType
        case clickDate
        case keyword
        case keywordId
        case region
    }
}

/// Apple Search Ads Integration class
/// Fetches attribution data for users who installed via Apple Search Ads
public class AppleSearchAdsIntegration {
    private var attributionData: AppleSearchAdsAttribution?
    private var fetched: Bool = false
    private var available: Bool = false
    private var debug: Bool = false

    public init() {}

    /// Initialize and fetch Apple Search Ads attribution
    public func initialize(debug: Bool = false) async {
        self.debug = debug

        // Check if AdServices is available (iOS 14.3+)
        #if os(iOS)
        #if canImport(AdServices)
        if #available(iOS 14.3, *) {
            self.available = true
            // FSR-29: do NOT await the fetch here. It used to block SDK init (and thus push
            // track() calls into the 50-cap preInitQueue) until Apple's AdServices API
            // responded — which can be slow, and per Apple's docs returns a transient 404 in
            // the first seconds after token generation (exactly first launch). Run it detached
            // with its own bounded retries/timeout; per-event merge picks up asa_* once it lands.
            Task { [weak self] in
                await self?.fetchAttribution()
            }
        } else {
            log("Apple Search Ads requires iOS 14.3+")
            self.available = false
        }
        #else
        log("AdServices framework not available")
        self.available = false
        #endif
        #else
        log("Apple Search Ads only available on iOS")
        self.available = false
        #endif
    }

    /// Fetch attribution data from Apple's AdServices API
    @discardableResult
    public func fetchAttribution() async -> AppleSearchAdsAttribution? {
        guard available else {
            return nil
        }

        // Only fetch once
        if fetched {
            return attributionData
        }

        #if os(iOS)
        #if canImport(AdServices)
        if #available(iOS 14.3, *) {
            do {
                // Get the attribution token from AdServices
                let token = try AAAttribution.attributionToken()

                // Send token to Apple's API to get attribution data
                guard let url = URL(string: "https://api-adservices.apple.com/api/v1/") else {
                    fetched = true
                    return nil
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
                request.httpBody = token.data(using: .utf8)
                // FSR-29: bound each call at 10s instead of URLSession's 60s default.
                request.timeoutInterval = 10

                // FSR-29: Apple's AdServices endpoint returns a transient 404 for the first few
                // seconds after token generation and documents up to 3 retries at ~5s. Without
                // this, a first-launch 404 permanently strips asa_* from the install event
                // (fetched=true on first non-200). Retry 404 specifically; other non-200s are final.
                var data = Data()
                var statusCode = 0
                let maxAttempts = 3
                for attempt in 1...maxAttempts {
                    let (respData, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        fetched = true
                        return nil
                    }
                    statusCode = httpResponse.statusCode
                    data = respData
                    if statusCode == 200 { break }
                    if statusCode == 404 && attempt < maxAttempts {
                        log("Apple Search Ads token not ready (404), retrying \(attempt)/\(maxAttempts - 1) in 5s")
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                    // Any other non-200, or 404 after the last attempt → give up.
                    fetched = true
                    return nil
                }

                guard statusCode == 200 else {
                    fetched = true
                    return nil
                }

                // Parse the response
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let hasAttribution = json["attribution"] as? Bool ?? false

                    let attribution = AppleSearchAdsAttribution(
                        attribution: hasAttribution,
                        orgId: json["orgId"] as? Int,
                        orgName: json["orgName"] as? String,
                        campaignId: json["campaignId"] as? Int,
                        campaignName: json["campaignName"] as? String,
                        adGroupId: json["adGroupId"] as? Int,
                        adGroupName: json["adGroupName"] as? String,
                        conversionType: json["conversionType"] as? String,
                        clickDate: json["clickDate"] as? String,
                        keyword: json["keyword"] as? String,
                        keywordId: json["keywordId"] as? Int,
                        region: json["region"] as? String
                    )

                    self.attributionData = attribution
                    self.fetched = true

                    if hasAttribution {
                        log("Apple Search Ads attribution found: campaign=\(attribution.campaignName ?? "unknown"), keyword=\(attribution.keyword ?? "none")")
                    } else {
                        log("No Apple Search Ads attribution (user did not come from search ad)")
                    }

                    return attribution
                }

                fetched = true
                return nil

            } catch {
                // Attribution token not available (user didn't come from Apple Search Ads)
                logError("Failed to fetch Apple Search Ads attribution: \(error.localizedDescription)")
                fetched = true
                return nil
            }
        }
        #endif
        #endif

        fetched = true
        return nil
    }

    /// Get cached attribution data
    public func getAttributionData() -> AppleSearchAdsAttribution? {
        return attributionData
    }

    /// Check if user came from Apple Search Ads
    public func hasAttribution() -> Bool {
        return attributionData?.attribution == true
    }

    /// Check if Apple Search Ads is available (iOS 14.3+)
    public func isAvailable() -> Bool {
        return available
    }

    /// Check if attribution has been fetched
    public func hasFetched() -> Bool {
        return fetched
    }

    /// Get attribution data as dictionary for event payload
    public func toDictionary() -> [String: Any]? {
        guard let data = attributionData, data.attribution else {
            return nil
        }

        var dict: [String: Any] = ["asa_attribution": true]

        if let orgId = data.orgId { dict["asa_org_id"] = orgId }
        if let orgName = data.orgName { dict["asa_org_name"] = orgName }
        if let campaignId = data.campaignId { dict["asa_campaign_id"] = campaignId }
        if let campaignName = data.campaignName { dict["asa_campaign_name"] = campaignName }
        if let adGroupId = data.adGroupId { dict["asa_adgroup_id"] = adGroupId }
        if let adGroupName = data.adGroupName { dict["asa_adgroup_name"] = adGroupName }
        if let conversionType = data.conversionType { dict["asa_conversion_type"] = conversionType }
        if let clickDate = data.clickDate { dict["asa_click_date"] = clickDate }
        if let keyword = data.keyword { dict["asa_keyword"] = keyword }
        if let keywordId = data.keywordId { dict["asa_keyword_id"] = keywordId }
        if let region = data.region { dict["asa_region"] = region }

        return dict
    }

    private func log(_ message: String) {
        if debug {
            print("[Datalyr/AppleSearchAds] \(message)")
        }
    }

    private func logError(_ message: String) {
        print("[Datalyr/AppleSearchAds] ERROR: \(message)")
    }
}

/// Shared singleton instance
public let appleSearchAdsIntegration = AppleSearchAdsIntegration()
