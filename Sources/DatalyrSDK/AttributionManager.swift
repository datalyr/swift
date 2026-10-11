import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Attribution Parameter Mapping

/// Attribution parameters to track
internal let ATTRIBUTION_PARAMS = [
    // Datalyr LYR tags (CRITICAL for your system!)
    "lyr", "datalyr", "dl_tag", "dl_campaign",
    
    // Facebook/Meta
    "fbclid",

    // TikTok
    "ttclid", "tt_click_id", "tiktok_click_id",

    // Google Ads
    "gclid", "wbraid", "gbraid", "dclid",

    // OpenAI Ads
    "oppref",

    // UTM Parameters (Standard)
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "utm_id", "utm_source_platform", "utm_creative_format", "utm_marketing_tactic",

    // Partner tracking parameters
    "partner_id", "affiliate_id", "referrer_id", "source_id",

    // Other platforms. `li_fat_id` is LinkedIn's real click-id param; the old `li_click_id`
    // entry captured nothing because LinkedIn never sends it (a previously persisted value is
    // still read and migrated — see AttributionData.migrateLegacyClickIds()).
    "twclid", "li_fat_id", "msclkid",

    // Snapchat appends `ScCid` (keys are lowercased before lookup, so `sccid`); `sclid` is
    // the canonical name ingest and the web SDK use. Both store as `sclid`.
    "sccid", "sclid",

    // AppLovin: `aleid` (click id) and `alart` (app-user id). Opaque, kept verbatim.
    "aleid", "alart",

    // Custom attribution parameters
    // FSR-86: removed irclickid / fb_click_id / fb_action_ids / fb_action_types / click_id —
    // they were whitelisted (so extractURLParameters collected them) but never assigned to
    // AttributionData and have no field, so they were parsed and dropped. The whitelist now
    // reflects exactly what is captured. (dclid is captured below — ingest supports it.)
    "campaign_id", "ad_id", "adset_id", "creative_id",
    "placement_id", "keyword", "matchtype", "network", "device",

    // Meta ad-entity breakdowns, delivered by the Play install referrer (Android) and
    // by the web→app bridge response. `placement` is the Meta macro's own name and is
    // NOT the same field as `placement_id` above (Feed/Reels/Story vs an id).
    "placement", "site_source_name"
]

/// Click ids from the web-attribution match response (deferred IP lookup and email lookup)
/// that are copied onto `$web_attribution_matched` and gap-filled into AttributionData, beyond
/// the original fbclid/gclid/ttclid/gbraid/wbraid. Only non-empty strings are copied: the API
/// answers `null` for absent ids.
internal let WEB_MATCH_PLATFORM_CLICK_IDS = ["twclid", "li_fat_id", "sclid", "aleid"]

/// The ids to copy from a lookup response onto `$web_attribution_matched`: the
/// `WEB_MATCH_PLATFORM_CLICK_IDS` plus `alart` when the response itself carries one (the
/// persisted `alart` is not attached to that event). Non-empty strings only; `null` / absent /
/// non-string values are left out.
internal func webMatchEventIds(_ attribution: [String: Any]) -> [String: String] {
    var out: [String: String] = [:]
    for key in WEB_MATCH_PLATFORM_CLICK_IDS + AttributionData.appUserIdKeys.sorted() {
        if let value = attribution[key] as? String, !value.isEmpty { out[key] = value }
    }
    return out
}

// MARK: - Attribution Manager

/// Manages attribution tracking for deep links and app installs
internal class AttributionManager {
    private var attributionData = AttributionData()
    private var isFirstLaunch = false
    /// Install time as a Date, for bounding the deferred web→app lookup. nil when the
    /// persisted stamp is absent or unparseable (install predates this stamp).
    private var installDate: Date?
    private let storage = DatalyrStorage.shared

    /// Initialize attribution tracking
    func initialize() async {
        debugLog("Initializing attribution manager...")
        
        // Check if this is first launch
        await checkFirstLaunch()
        
        // Load existing attribution data
        await loadAttributionData()
        
        // Set up deep link handling
        setupDeepLinkHandling()
        
        // Handle any pending URL if app was launched from deep link
        await handleLaunchURL()
        
        debugLog("Attribution manager initialized", data: attributionData.toDictionary())
    }
    
    /// Check if this is the first launch and track install
    private func checkFirstLaunch() async {
        let firstLaunchTime = await storage.getString(StorageKeys.firstLaunchTime)
        
        if firstLaunchTime == nil {
            // This is the first launch
            isFirstLaunch = true
            let now = Date()
            let installTime = DateFormatter.iso8601.string(from: now)

            attributionData.installTime = installTime
            attributionData.firstOpenTime = installTime
            installDate = now

            await storage.setString(StorageKeys.firstLaunchTime, value: installTime)
            debugLog("First launch detected, install time: \(installTime)")
        } else {
            isFirstLaunch = false
            attributionData.installTime = firstLaunchTime
            installDate = firstLaunchTime.flatMap { DateFormatter.iso8601.date(from: $0) }
            debugLog("Returning user, install time: \(firstLaunchTime ?? "unknown")")
        }
    }
    
    /// Load persisted attribution data
    private func loadAttributionData() async {
        if var savedData = await storage.getCodable(StorageKeys.attributionData, type: AttributionData.self) {
            // Installs from 2.1.16 and earlier may have persisted `li_click_id`; carry it to
            // `li_fat_id` once and re-save so the legacy key is gone from storage.
            let migrated = savedData.migrateLegacyClickIds()
            attributionData = savedData
            if migrated {
                await saveAttributionData()
            }
            debugLog("Loaded attribution data", data: attributionData.toDictionary())
        }
    }
    
    /// Save attribution data to storage
    private func saveAttributionData() async {
        await storage.setCodable(StorageKeys.attributionData, value: attributionData)
        debugLog("Attribution data saved")
    }
    
    /// Set up deep link handling
    private func setupDeepLinkHandling() {
        // Note: In a real implementation, you would set up URL scheme handling
        // This is typically done in the AppDelegate or SceneDelegate
        debugLog("Deep link handling configured")
    }
    
    /// Handle URL that launched the app
    private func handleLaunchURL() async {
        // In a real implementation, this would check if the app was launched
        // with a URL and process any attribution parameters
        debugLog("Checking for launch URL...")
    }
    
    /// Process a deep link URL for attribution parameters
    /// Parse a deep link, persist its attribution params, and RETURN the extracted params
    /// (click-ids + lyr, lowercased keys) so the caller can emit a `$deep_link` event — TR-17:
    /// the params were only persisted locally + surfaced to Superwall/RevenueCat client
    /// attributes, never sent to Datalyr ingest, so server attribution / CAPI couldn't see a
    /// post-install re-engagement ad-click. Empty return = nothing attributable in the URL.
    @discardableResult
    func handleDeepLink(_ url: URL) async -> [String: String] {
        debugLog("Processing deep link: \(url.absoluteString)")

        // Extract URL parameters
        let parameters = extractURLParameters(from: url)

        if !parameters.isEmpty {
            await processAttributionParameters(parameters)
            attributionData.deepLinkUrl = url.absoluteString
            attributionData.attributionTimestamp = DateFormatter.iso8601.string(from: Date())
            // FSR-34: stamp a numeric capture-time so the journey recorder can detect that
            // THIS is a fresh touch (vs a relaunch over stale persisted attribution).
            attributionData.attributionCapturedAt = Date().timeIntervalSince1970 * 1000

            await saveAttributionData()
            debugLog("Deep link processed with \(parameters.count) parameters")
        }
        return parameters
    }
    
    /// Extract parameters from URL
    private func extractURLParameters(from url: URL) -> [String: String] {
        var parameters: [String: String] = [:]
        
        // Parse URL components
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return parameters
        }
        
        // Extract query parameters. Empty values (`?sclid=`) are dropped here and below: stored,
        // they became the touch's click type and overwrote a real stored value. (RN drops them too.)
        if let queryItems = components.queryItems {
            for item in queryItems {
                if let value = item.value, !value.isEmpty, ATTRIBUTION_PARAMS.contains(item.name.lowercased()) {
                    parameters[item.name.lowercased()] = value
                }
            }
        }
        
        // Extract fragment parameters (after #)
        if let fragment = components.fragment {
            var fragmentComponents = URLComponents()
            fragmentComponents.query = fragment
            
            if let fragmentItems = fragmentComponents.queryItems {
                for item in fragmentItems {
                    if let value = item.value, !value.isEmpty, ATTRIBUTION_PARAMS.contains(item.name.lowercased()) {
                        parameters[item.name.lowercased()] = value
                    }
                }
            }
        }
        
        return parameters
    }
    
    /// Process attribution parameters and update attribution data
    private func processAttributionParameters(_ parameters: [String: String]) async {
        // Datalyr LYR System (CRITICAL!)
        attributionData.lyr = parameters["lyr"] ?? attributionData.lyr
        attributionData.datalyr = parameters["datalyr"] ?? attributionData.datalyr
        attributionData.dlTag = parameters["dl_tag"] ?? attributionData.dlTag
        attributionData.dlCampaign = parameters["dl_campaign"] ?? attributionData.dlCampaign
        
        // UTM Parameters
        attributionData.utmSource = parameters["utm_source"] ?? attributionData.utmSource
        attributionData.utmMedium = parameters["utm_medium"] ?? attributionData.utmMedium
        attributionData.utmCampaign = parameters["utm_campaign"] ?? attributionData.utmCampaign
        attributionData.utmTerm = parameters["utm_term"] ?? attributionData.utmTerm
        attributionData.utmContent = parameters["utm_content"] ?? attributionData.utmContent
        attributionData.utmId = parameters["utm_id"] ?? attributionData.utmId
        attributionData.utmSourcePlatform = parameters["utm_source_platform"] ?? attributionData.utmSourcePlatform
        attributionData.utmCreativeFormat = parameters["utm_creative_format"] ?? attributionData.utmCreativeFormat
        attributionData.utmMarketingTactic = parameters["utm_marketing_tactic"] ?? attributionData.utmMarketingTactic
        
        // Platform Click IDs
        attributionData.fbclid = parameters["fbclid"] ?? attributionData.fbclid
        attributionData.ttclid = parameters["ttclid"] ?? parameters["tt_click_id"] ?? parameters["tiktok_click_id"] ?? attributionData.ttclid
        attributionData.gclid = parameters["gclid"] ?? attributionData.gclid
        // gbraid/wbraid are Google's iOS click-ids (sent in place of gclid under ATT/ITP);
        // they're parsed into ATTRIBUTION_PARAMS and read by getRevenueCatAttributes(), but
        // were never assigned here — so Google App-campaign attribution was dropped on iOS.
        attributionData.gbraid = parameters["gbraid"] ?? attributionData.gbraid
        attributionData.wbraid = parameters["wbraid"] ?? attributionData.wbraid
        // FSR-86: dclid was whitelisted but never assigned; ingest's clickIdMapping supports it.
        attributionData.dclid = parameters["dclid"] ?? attributionData.dclid
        attributionData.oppref = parameters["oppref"] ?? attributionData.oppref
        attributionData.twclid = parameters["twclid"] ?? attributionData.twclid
        attributionData.liFatId = parameters["li_fat_id"] ?? attributionData.liFatId
        attributionData.sclid = parameters["sccid"] ?? parameters["sclid"] ?? attributionData.sclid
        attributionData.aleid = parameters["aleid"] ?? attributionData.aleid
        attributionData.alart = parameters["alart"] ?? attributionData.alart
        attributionData.msclkid = parameters["msclkid"] ?? attributionData.msclkid
        
        // Partner & Affiliate Tracking
        attributionData.partnerId = parameters["partner_id"] ?? attributionData.partnerId
        attributionData.affiliateId = parameters["affiliate_id"] ?? attributionData.affiliateId
        attributionData.referrerId = parameters["referrer_id"] ?? attributionData.referrerId
        attributionData.sourceId = parameters["source_id"] ?? attributionData.sourceId
        
        // Campaign Details
        attributionData.campaignId = parameters["campaign_id"] ?? attributionData.campaignId
        attributionData.adId = parameters["ad_id"] ?? attributionData.adId
        attributionData.adsetId = parameters["adset_id"] ?? attributionData.adsetId
        attributionData.creativeId = parameters["creative_id"] ?? attributionData.creativeId
        attributionData.placementId = parameters["placement_id"] ?? attributionData.placementId
        attributionData.placement = parameters["placement"] ?? attributionData.placement
        attributionData.siteSourceName = parameters["site_source_name"] ?? attributionData.siteSourceName
        attributionData.keyword = parameters["keyword"] ?? attributionData.keyword
        attributionData.matchtype = parameters["matchtype"] ?? attributionData.matchtype
        attributionData.network = parameters["network"] ?? attributionData.network
        attributionData.device = parameters["device"] ?? attributionData.device
        
        // Map UTM to standard attribution fields
        if let utmSource = attributionData.utmSource {
            attributionData.campaignSource = utmSource
        }
        if let utmMedium = attributionData.utmMedium {
            attributionData.campaignMedium = utmMedium
        }
        if let utmCampaign = attributionData.utmCampaign {
            attributionData.campaignName = utmCampaign
        }
        if let utmTerm = attributionData.utmTerm {
            attributionData.campaignTerm = utmTerm
        }
        if let utmContent = attributionData.utmContent {
            attributionData.campaignContent = utmContent
        }
        
        debugLog("Attribution parameters processed", data: parameters)
    }
    
    // MARK: - Public API
    
    /// Get current attribution data
    func getAttributionData() -> AttributionData {
        return attributionData
    }
    
    /// Check if this is an install (first launch)
    func isInstall() -> Bool {
        return isFirstLaunch
    }
    
    /// Track install and return attribution data
    func trackInstall() -> AttributionData {
        if isFirstLaunch {
            let installTime = DateFormatter.iso8601.string(from: Date())
            attributionData.installTime = installTime
            attributionData.firstOpenTime = installTime
            
            Task {
                await saveAttributionData()
            }
            
            debugLog("Install tracked with attribution data")
        }
        
        return attributionData
    }
    
    // MARK: - Deferred web→app lookup state

    /// The IP lookup is the ONLY web→app bridge on iOS, and it runs during init — exactly
    /// when a freshly installed device is most likely to have no usable network (App Store
    /// hand-off, captive portal, airplane mode). First launch is therefore the wrong gate:
    /// `firstLaunchTime` is persisted during init whether or not the lookup ever reached the
    /// server, so one offline cold start forfeited attribution for the life of the install.
    /// Eligibility is instead "no definitive answer yet", bounded two ways.
    ///
    /// Both bounds are hard stops, so retrying cannot continue indefinitely:
    /// - the server only matches a web touch to this IP within its match window, so once
    ///   that window has passed since install there is nothing left to match and elapsed
    ///   time can never shrink back;
    /// - the attempt counter is persisted BEFORE each request is issued, so attempts are
    ///   spent even by requests that never return, and a device with a broken/rolled-back
    ///   clock still runs out.
    ///
    /// This MUST NOT be tighter than the server's match reach, or the SDK stops asking
    /// while the server would still have answered — the original 60-minute bound sat
    /// against a server configured for 180 and forfeited two thirds of the window.
    /// Now 7 days, matching the server's tier-2 fingerprint matcher
    /// (DEFERRED_FP_MATCH_MAX_DAYS): the click history is server-side, so a device
    /// that was offline at install — or whose first attempts failed in transit — can
    /// still recover its attribution days later. The attempt cap, not the window, is
    /// what bounds request volume.
    private static let deferredLookupWindow: TimeInterval = 7 * 24 * 3600
    private static let maxDeferredLookupAttempts = 3

    /// Whether the deferred web→app IP lookup should be attempted on this launch.
    func shouldAttemptDeferredLookup() async -> Bool {
        if await storage.getBool(StorageKeys.deferredLookupResolved) == true {
            return false
        }

        // An install whose time is unknown cannot be bounded by the match window, and is by
        // definition not a fresh install of this SDK version — nothing to recover.
        guard let installDate = installDate else {
            debugLog("Deferred lookup not attempted: install time unknown")
            return false
        }

        let elapsed = Date().timeIntervalSince(installDate)
        guard elapsed >= 0, elapsed < Self.deferredLookupWindow else {
            debugLog("Deferred lookup not attempted: outside the server's IP match window")
            return false
        }

        let attempts = Int(await storage.getDouble(StorageKeys.deferredLookupAttempts) ?? 0)
        guard attempts < Self.maxDeferredLookupAttempts else {
            debugLog("Deferred lookup not attempted: attempt limit reached (\(attempts))")
            return false
        }

        return true
    }

    /// Count an issued lookup request. Called before the request goes out so an attempt that
    /// never returns (process killed mid-flight) still consumes budget.
    func recordDeferredLookupAttempt() async {
        let attempts = await storage.getDouble(StorageKeys.deferredLookupAttempts) ?? 0
        await storage.setDouble(StorageKeys.deferredLookupAttempts, value: attempts + 1)
    }

    /// Minutes since install, or nil when the install time is unknown. Drives the
    /// ingest-lag retry: a `no_candidates` answer in the first hour may just mean the
    /// click has not landed in the analytics store yet.
    func installAgeMinutes() -> Double? {
        guard let installDate = installDate else { return nil }
        let elapsed = Date().timeIntervalSince(installDate)
        return elapsed >= 0 ? elapsed / 60 : nil
    }

    /// Record that the server answered definitively — matched or not. Terminal: a genuine
    /// "no web touch for this IP" must not re-ask on every launch.
    func markDeferredLookupResolved() async {
        await storage.setBool(StorageKeys.deferredLookupResolved, value: true)
        debugLog("Deferred lookup resolved; no further attempts this install")
    }

    /// Set attribution data manually
    func setAttributionData(_ data: AttributionData) async {
        attributionData = data
        attributionData.migrateLegacyClickIds()
        await saveAttributionData()
        debugLog("Attribution data set manually")
    }

    /// Merge web attribution data into mobile session
    /// Called when web-to-app attribution is resolved via email
    func mergeWebAttribution(_ webAttribution: [String: Any]) async {
        debugLog("Merging web attribution data", data: webAttribution)

        // Only merge if we don't already have attribution data
        // Web attribution takes precedence for first-touch
        if attributionData.fbclid == nil, let fbclid = webAttribution["fbclid"] as? String {
            attributionData.fbclid = fbclid
        }
        if attributionData.gclid == nil, let gclid = webAttribution["gclid"] as? String {
            attributionData.gclid = gclid
        }
        if attributionData.ttclid == nil, let ttclid = webAttribution["ttclid"] as? String {
            attributionData.ttclid = ttclid
        }
        if attributionData.oppref == nil, let oppref = webAttribution["oppref"] as? String {
            attributionData.oppref = oppref
        }
        // FSR-30: gbraid/wbraid/lyr were forwarded by BOTH web→app recovery paths
        // (DatalyrSDK.swift:459-460/586-587) and carried in the lookup response, but never
        // merged into the persisted struct. Under ATT, Google App campaigns produce
        // gbraid/wbraid (not gclid), so the recovered Google-iOS click-id never reached
        // client-side attribution / getRevenueCatAttributes() (which DOES emit these keys).
        // Same gap-fill precedence as the others (only fill when absent).
        if attributionData.gbraid == nil, let gbraid = webAttribution["gbraid"] as? String {
            attributionData.gbraid = gbraid
        }
        if attributionData.wbraid == nil, let wbraid = webAttribution["wbraid"] as? String {
            attributionData.wbraid = wbraid
        }
        if attributionData.lyr == nil, let lyr = webAttribution["lyr"] as? String {
            attributionData.lyr = lyr
        }
        // X, LinkedIn, Snapchat and AppLovin click ids. The lookup response already carried
        // twclid / li_fat_id / sclid and they were dropped here, so a matched install from
        // those platforms reached later events with no click id. Same gap-fill precedence.
        if attributionData.twclid == nil, let v = webAttribution["twclid"] as? String, !v.isEmpty {
            attributionData.twclid = v
        }
        if attributionData.liFatId == nil, let v = webAttribution["li_fat_id"] as? String, !v.isEmpty {
            attributionData.liFatId = v
        }
        if attributionData.sclid == nil, let v = webAttribution["sclid"] as? String, !v.isEmpty {
            attributionData.sclid = v
        }
        if attributionData.aleid == nil, let v = webAttribution["aleid"] as? String, !v.isEmpty {
            attributionData.aleid = v
        }

        // Ad ENTITY ids recovered from the matched web click. Without these the app side
        // knew the campaign only by NAME (via the UTMs below), and a name join back to
        // synced spend breaks retroactively the moment a buyer renames a campaign
        // mid-flight — so an install could be perfectly matched and still land in the
        // unattributed bucket a week later. Same gap-fill precedence as the click ids.
        if attributionData.campaignId == nil, let v = webAttribution["campaign_id"] as? String, !v.isEmpty {
            attributionData.campaignId = v
        }
        if attributionData.adsetId == nil, let v = webAttribution["adset_id"] as? String, !v.isEmpty {
            attributionData.adsetId = v
        }
        if attributionData.adId == nil, let v = webAttribution["ad_id"] as? String, !v.isEmpty {
            attributionData.adId = v
        }
        if attributionData.placement == nil, let v = webAttribution["placement"] as? String, !v.isEmpty {
            attributionData.placement = v
        }
        if attributionData.siteSourceName == nil, let v = webAttribution["site_source_name"] as? String, !v.isEmpty {
            attributionData.siteSourceName = v
        }

        // Merge UTM parameters
        if attributionData.utmSource == nil, let utmSource = webAttribution["utm_source"] as? String {
            attributionData.utmSource = utmSource
            attributionData.campaignSource = utmSource
        }
        if attributionData.utmMedium == nil, let utmMedium = webAttribution["utm_medium"] as? String {
            attributionData.utmMedium = utmMedium
            attributionData.campaignMedium = utmMedium
        }
        if attributionData.utmCampaign == nil, let utmCampaign = webAttribution["utm_campaign"] as? String {
            attributionData.utmCampaign = utmCampaign
            attributionData.campaignName = utmCampaign
        }
        if attributionData.utmContent == nil, let utmContent = webAttribution["utm_content"] as? String {
            attributionData.utmContent = utmContent
            attributionData.campaignContent = utmContent
        }
        if attributionData.utmTerm == nil, let utmTerm = webAttribution["utm_term"] as? String {
            attributionData.utmTerm = utmTerm
            attributionData.campaignTerm = utmTerm
        }

        // FSR-34: a web→app merge is a fresh attribution event — stamp the capture-time so the
        // journey recorder treats it as new rather than relaunch-over-stale.
        attributionData.attributionCapturedAt = Date().timeIntervalSince1970 * 1000

        // Save merged attribution data
        await saveAttributionData()

        debugLog("Web attribution merged successfully")
    }

    /// Clear attribution data
    func clearAttributionData() async {
        attributionData = AttributionData()
        await storage.removeValue(StorageKeys.attributionData)
        debugLog("Attribution data cleared")
    }
    
    /// Get attribution summary
    func getAttributionSummary() -> (hasAttribution: Bool, isInstall: Bool, source: String, campaign: String, clickIds: [String]) {
        let hasAttribution = attributionData.utmSource != nil || 
                           attributionData.fbclid != nil || 
                           attributionData.gclid != nil ||
                           attributionData.lyr != nil
        
        // Resolved as an explicit ladder rather than a long mixed-type `??` chain:
        // the ternaries each yield String?, and chaining them with `??` makes the Swift
        // type-checker time out ("unable to type-check in reasonable time"). Same precedence.
        let source: String
        if let utmSource = attributionData.utmSource {
            source = utmSource
        } else if let campaignSource = attributionData.campaignSource {
            source = campaignSource
        } else if attributionData.fbclid != nil {
            source = "facebook"
        } else if attributionData.gclid != nil {
            source = "google"
        } else if attributionData.ttclid != nil {
            source = "tiktok"
        } else if attributionData.oppref != nil {
            source = "openai"
        } else {
            source = "organic"
        }
        
        let campaign = attributionData.utmCampaign ?? 
                      attributionData.campaignName ?? 
                      attributionData.dlCampaign ?? 
                      "unknown"
        
        var clickIds: [String] = []
        if let fbclid = attributionData.fbclid { clickIds.append("fbclid:\(fbclid)") }
        if let gclid = attributionData.gclid { clickIds.append("gclid:\(gclid)") }
        if let ttclid = attributionData.ttclid { clickIds.append("ttclid:\(ttclid)") }
        if let oppref = attributionData.oppref { clickIds.append("oppref:\(oppref)") }
        if let lyr = attributionData.lyr { clickIds.append("lyr:\(lyr)") }
        
        return (
            hasAttribution: hasAttribution,
            isInstall: isFirstLaunch,
            source: source,
            campaign: campaign,
            clickIds: clickIds
        )
    }
} 