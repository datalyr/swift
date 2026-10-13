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
    /// Now 7 days, matching the server's tier-2 device-context matcher
    /// (DEFERRED_FP_MATCH_MAX_DAYS): the click history is server-side, so a device
    /// that was offline at install — or whose first attempts failed in transit — can
    /// still recover its attribution days later. The attempt cap, not the window, is
    /// what bounds request volume.
    private static let deferredLookupWindow: TimeInterval = 7 * 24 * 3600
    private static let maxDeferredLookupAttempts = 3

    /// Whether the deferred web→app IP lookup should be attempted now. `liveATTStatus` is
    /// the current ATT status: when the server last declined at exactly this status
    /// (`att_not_authorized`), asking again would get the same answer, so it is skipped
    /// without spending an attempt until the status changes.
    func shouldAttemptDeferredLookup(liveATTStatus: UInt? = nil) async -> Bool {
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

        if let live = liveATTStatus, let refused = await deferredLookupRefusedATTStatus(), refused == live {
            debugLog("Deferred lookup not attempted: waiting for an ATT status change (declined at \(refused))")
            return false
        }

        return true
    }

    /// ATT status of the last `att_not_authorized` answer, or nil when the last answer was
    /// anything else (or there was none).
    func deferredLookupRefusedATTStatus() async -> UInt? {
        guard let v = await storage.getDouble(StorageKeys.deferredLookupRefusedATTStatus), v >= 0 else { return nil }
        return UInt(v)
    }

    func recordDeferredLookupATTRefusal(status: UInt) async {
        await storage.setDouble(StorageKeys.deferredLookupRefusedATTStatus, value: Double(status))
    }

    func clearDeferredLookupATTRefusal() async {
        await storage.removeValue(StorageKeys.deferredLookupRefusedATTStatus)
    }

    /// True when the `att_not_authorized` miss has not been reported yet for this ATT status
    /// on this install; records it as reported.
    func claimATTMissReport(status: UInt) async -> Bool {
        let last = await storage.getDouble(StorageKeys.deferredLookupATTMissReportedStatus)
        if let last = last, last == Double(status) { return false }
        await storage.setDouble(StorageKeys.deferredLookupATTMissReportedStatus, value: Double(status))
        return true
    }

    /// Count an issued lookup request. Called before the request goes out so an attempt that
    /// never returns (process killed mid-flight) still consumes budget.
    func recordDeferredLookupAttempt() async {
        let attempts = await storage.getDouble(StorageKeys.deferredLookupAttempts) ?? 0
        await storage.setDouble(StorageKeys.deferredLookupAttempts, value: attempts + 1)
    }

    /// Give back the attempt spent on a request the server declined to match only because
    /// ATT is not authorized yet (`att_not_authorized`). That answer says nothing about
    /// whether a web touch exists, so it must not use up one of the install's attempts:
    /// the lookup that runs after the user allows tracking needs that budget.
    func refundDeferredLookupAttempt() async {
        let attempts = await storage.getDouble(StorageKeys.deferredLookupAttempts) ?? 0
        await storage.setDouble(StorageKeys.deferredLookupAttempts, value: max(0, attempts - 1))
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
// MARK: - Deferred web→app lookup: request body, answer handling, scheduling

/// What one deferred-lookup answer means for the install's lookup state.
internal enum DeferredLookupDisposition: Equatable {
    /// The server answered definitively (matched or not). No further attempts this install.
    case resolve
    /// Nothing usable came back (transport error, 5xx, fresh `no_candidates`). The attempt
    /// stays spent and a later launch inside the window may retry.
    case retryLater
    /// The server will not match this install until ATT is authorized
    /// (`att_not_authorized`). Not an answer about the install: the attempt is refunded and
    /// the lookup runs again once the user allows tracking.
    case awaitingATT
}

internal enum DeferredLookup {
    /// The miss reason the server sends when the workspace matches iOS installs only with
    /// ATT authorized and this request did not carry `att_status: 3`.
    static let attNotAuthorizedReason = "att_not_authorized"

    /// The JSON body for POST /attribution/deferred-lookup. `att_status` is the live ATT
    /// status (0 notDetermined, 1 restricted, 2 denied, 3 authorized) as a plain Int — the
    /// server compares it numerically.
    static func requestBody(
        osVersion: String,
        deviceModel: String,
        timezone: String,
        language: String?,
        attStatus: UInt
    ) -> [String: Any] {
        var body: [String: Any] = [
            "platform": "ios",
            "os_version": osVersion,
            "device_model": deviceModel,
            "timezone": timezone,
            "att_status": Int(min(attStatus, UInt(Int.max))),
        ]
        if let language = language, !language.isEmpty {
            body["language"] = language
        }
        return body
    }

    /// Disposition of a non-200 response. 5xx/408/429 are transient; anything else is
    /// definitive for this install (disabled route, rejected key, malformed request).
    static func disposition(forHTTPStatus statusCode: Int) -> DeferredLookupDisposition {
        let retryable = statusCode >= 500 || statusCode == 408 || statusCode == 429
        return retryable ? .retryLater : .resolve
    }

    /// Disposition of a parsed 200 body.
    ///
    /// A parsed 200 is the server's definitive answer, matched or not, with two exceptions:
    /// - `att_not_authorized`: the server declined to look, so there is no answer yet;
    /// - `no_candidates` inside the first hour after install may just be ingest lag
    ///   (click → queue → analytics store takes seconds to minutes), so it stays eligible
    ///   for one more launch. The attempt cap bounds that retry.
    static func disposition(forBody json: [String: Any], installAgeMinutes: Double?) -> DeferredLookupDisposition {
        guard (json["found"] as? Bool) == false else { return .resolve }
        let reason = json["reason"] as? String ?? "no_candidates"
        if reason == attNotAuthorizedReason { return .awaitingATT }
        if reason == "no_candidates" && (installAgeMinutes ?? .infinity) < 60 { return .retryLater }
        return .resolve
    }
}

/// Per-launch scheduling state for the deferred lookup. Thread-safe.
///
/// - At most one lookup is in flight. A run requested while one is in flight (typically
///   the user allowing tracking while the launch lookup is still waiting on the network)
///   is queued — the latest request wins — and runs, with its own eligibility check, once
///   the in-flight one finishes. So a post-grant lookup is not lost and two never overlap.
/// - Tracks the last ATT status the SDK observed, so a transition to authorized — via
///   requestTrackingAuthorization, updateTrackingAuthorization, or the app calling
///   ATTrackingManager itself and coming back to the foreground — is seen exactly once.
///   Whether that transition re-runs the lookup is decided by the caller (only after an
///   `att_not_authorized` answer).
internal final class DeferredLookupCoordinator {
    typealias Pass = (isEligible: () async -> Bool, lookup: () async -> Void)

    private let lock = NSLock()
    private var inFlight = false
    private var queued: Pass?
    private var lastObservedATTStatus: UInt?

    /// Run `lookup` if `isEligible` says so, single-flight (see type doc).
    func run(isEligible: @escaping () async -> Bool, lookup: @escaping () async -> Void) async {
        var pass: Pass? = (isEligible, lookup)
        let claimed: Bool = lock.withLock {
            if inFlight {
                queued = pass
                return false
            }
            inFlight = true
            return true
        }
        guard claimed else { return }
        while let current = pass {
            if await current.isEligible() {
                await current.lookup()
            }
            pass = lock.withLock {
                let next = queued
                queued = nil
                if next == nil { inFlight = false }
                return next
            }
        }
    }

    var isInFlight: Bool {
        lock.withLock { inFlight }
    }

    /// Record the ATT status just read. Returns true only on a transition from a known
    /// non-authorized status to authorized (3). The first observation is a baseline, not a
    /// transition: an install that was already authorized at launch runs its lookup from
    /// initialize() with `att_status: 3` and needs no second one.
    func observeATTStatus(_ status: UInt) -> Bool {
        lock.withLock {
            let previous = lastObservedATTStatus
            lastObservedATTStatus = status
            guard let previous = previous else { return false }
            return previous != 3 && status == 3
        }
    }
}
