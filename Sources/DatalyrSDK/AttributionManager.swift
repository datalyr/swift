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
    "fbclid", "fb_click_id", "fb_action_ids", "fb_action_types",
    
    // TikTok
    "ttclid", "tt_click_id", "tiktok_click_id",
    
    // Google Ads
    "gclid", "wbraid", "gbraid", "dclid",
    
    // UTM Parameters (Standard)
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "utm_id", "utm_source_platform", "utm_creative_format", "utm_marketing_tactic",
    
    // Partner tracking parameters
    "partner_id", "affiliate_id", "referrer_id", "source_id",
    
    // Other platforms
    "twclid", "li_click_id", "msclkid", "irclickid",
    
    // Custom attribution parameters
    "click_id", "campaign_id", "ad_id", "adset_id", "creative_id",
    "placement_id", "keyword", "matchtype", "network", "device"
]

// MARK: - Attribution Manager

/// Manages attribution tracking for deep links and app installs
internal class AttributionManager {
    private var attributionData = AttributionData()
    private var isFirstLaunch = false
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
            let installTime = DateFormatter.iso8601.string(from: Date())
            
            attributionData.installTime = installTime
            attributionData.firstOpenTime = installTime
            
            await storage.setString(StorageKeys.firstLaunchTime, value: installTime)
            debugLog("First launch detected, install time: \(installTime)")
        } else {
            isFirstLaunch = false
            attributionData.installTime = firstLaunchTime
            debugLog("Returning user, install time: \(firstLaunchTime ?? "unknown")")
        }
    }
    
    /// Load persisted attribution data
    private func loadAttributionData() async {
        if let savedData = await storage.getCodable(StorageKeys.attributionData, type: AttributionData.self) {
            attributionData = savedData
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
    func handleDeepLink(_ url: URL) async {
        debugLog("Processing deep link: \(url.absoluteString)")
        
        // Extract URL parameters
        let parameters = extractURLParameters(from: url)
        
        if !parameters.isEmpty {
            await processAttributionParameters(parameters)
            attributionData.deepLinkUrl = url.absoluteString
            attributionData.attributionTimestamp = DateFormatter.iso8601.string(from: Date())
            
            await saveAttributionData()
            debugLog("Deep link processed with \(parameters.count) parameters")
        }
    }
    
    /// Extract parameters from URL
    private func extractURLParameters(from url: URL) -> [String: String] {
        var parameters: [String: String] = [:]
        
        // Parse URL components
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return parameters
        }
        
        // Extract query parameters
        if let queryItems = components.queryItems {
            for item in queryItems {
                if let value = item.value, ATTRIBUTION_PARAMS.contains(item.name.lowercased()) {
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
                    if let value = item.value, ATTRIBUTION_PARAMS.contains(item.name.lowercased()) {
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
        attributionData.twclid = parameters["twclid"] ?? attributionData.twclid
        attributionData.liClickId = parameters["li_click_id"] ?? attributionData.liClickId
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
    
    /// Set attribution data manually
    func setAttributionData(_ data: AttributionData) async {
        attributionData = data
        await saveAttributionData()
        debugLog("Attribution data set manually")
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
        
        let source = attributionData.utmSource ?? 
                    attributionData.campaignSource ?? 
                    (attributionData.fbclid != nil ? "facebook" : nil) ??
                    (attributionData.gclid != nil ? "google" : nil) ??
                    (attributionData.ttclid != nil ? "tiktok" : nil) ??
                    "organic"
        
        let campaign = attributionData.utmCampaign ?? 
                      attributionData.campaignName ?? 
                      attributionData.dlCampaign ?? 
                      "unknown"
        
        var clickIds: [String] = []
        if let fbclid = attributionData.fbclid { clickIds.append("fbclid:\(fbclid)") }
        if let gclid = attributionData.gclid { clickIds.append("gclid:\(gclid)") }
        if let ttclid = attributionData.ttclid { clickIds.append("ttclid:\(ttclid)") }
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