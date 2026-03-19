import Foundation
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

// MARK: - Platform Integration Manager

/// Manages platform integrations (Apple Search Ads, IDFA/ATT)
/// Conversion event routing to ad platforms (Meta, TikTok, Google) is handled
/// server-side via the postback system — no client-side ad SDKs needed.
internal class PlatformIntegrationManager {
    private var asaIntegration: AppleSearchAdsIntegration?

    /// Initialize platform integrations based on configuration
    func initialize(config: DatalyrConfig) async {
        // Initialize Apple Search Ads (always, if attribution enabled)
        if config.enableAttribution {
            asaIntegration = AppleSearchAdsIntegration()
            await asaIntegration?.initialize(debug: config.debug)
        }

        debugLog("Platform integrations initialized", data: [
            "asa_enabled": asaIntegration?.isAvailable() ?? false
        ])
    }

    // MARK: - ATT / IDFA

    /// Check if tracking is authorized (ATT)
    func isTrackingAuthorized() -> Bool {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return ATTrackingManager.trackingAuthorizationStatus == .authorized
        }
        #endif
        return true
    }

    /// Get ATT authorization status
    /// Returns: 0 = notDetermined, 1 = restricted, 2 = denied, 3 = authorized
    func getTrackingAuthorizationStatus() -> UInt {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return ATTrackingManager.trackingAuthorizationStatus.rawValue
        }
        #endif
        return 3 // authorized (pre-iOS 14)
    }

    /// Get IDFA (Identifier for Advertisers) if authorized
    /// Returns nil if ATT not authorized or IDFA not available
    func getIDFA() -> String? {
        #if canImport(AdSupport)
        guard isTrackingAuthorized() else { return nil }
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        // All zeros means tracking is not available
        if idfa == "00000000-0000-0000-0000-000000000000" { return nil }
        return idfa
        #else
        return nil
        #endif
    }

    /// Get advertiser data for server-side CAPI
    /// Returns dictionary with idfa, att_status, tracking_authorized
    func getAdvertiserData() -> [String: Any] {
        var data: [String: Any] = [
            "att_status": getTrackingAuthorizationStatus(),
            "tracking_authorized": isTrackingAuthorized()
        ]
        if let idfa = getIDFA() {
            data["idfa"] = idfa
        }
        return data
    }

    // MARK: - Apple Search Ads

    /// Check if Apple Search Ads integration is available
    func isAppleSearchAdsAvailable() -> Bool {
        return asaIntegration?.isAvailable() ?? false
    }

    /// Get Apple Search Ads attribution data
    func getAppleSearchAdsAttribution() -> AppleSearchAdsAttribution? {
        return asaIntegration?.getAttributionData()
    }

    /// Get Apple Search Ads attribution as dictionary for event payloads
    func getAppleSearchAdsData() -> [String: Any]? {
        return asaIntegration?.toDictionary()
    }
}
