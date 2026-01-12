import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(FBSDKCoreKit)
import FBSDKCoreKit
#endif

/// Manages Meta (Facebook) SDK integration for deferred deep linking and event forwarding
internal class MetaIntegration {
    private var isInitialized = false
    private let appId: String
    private let clientToken: String?
    private let enableAttribution: Bool
    private let forwardEvents: Bool
    private let debug: Bool

    /// Cached IDFA (only captured when ATT authorized)
    private var cachedIDFA: String?

    /// Zero UUID constant for comparison
    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    init(appId: String, clientToken: String?, enableAttribution: Bool, forwardEvents: Bool, debug: Bool) {
        self.appId = appId
        self.clientToken = clientToken
        self.enableAttribution = enableAttribution
        self.forwardEvents = forwardEvents
        self.debug = debug
    }

    /// Initialize Meta SDK
    func initialize() async {
        #if canImport(FBSDKCoreKit)
        await MainActor.run {
            // Configure Meta SDK settings
            Settings.shared.appID = appId
            if let clientToken = clientToken {
                Settings.shared.clientToken = clientToken
            }

            // Set advertiser tracking based on current ATT status
            updateTrackingAuthorization()

            // Enable debug logging if needed
            if debug {
                Settings.shared.loggingBehaviors = [.appEvents, .networkRequests]
            }

            // Initialize the SDK
            ApplicationDelegate.shared.application(
                UIApplication.shared,
                didFinishLaunchingWithOptions: nil
            )

            isInitialized = true
            debugLog("Meta SDK initialized with App ID: \(appId)")
        }
        #else
        debugLog("Meta SDK not available - FBSDKCoreKit not imported")
        #endif
    }

    /// Update Meta SDK tracking based on ATT authorization status
    /// Call this after user responds to ATT prompt
    func updateTrackingAuthorization() {
        #if canImport(FBSDKCoreKit)
        DispatchQueue.main.async { [weak self] in
            #if os(iOS)
            #if canImport(AppTrackingTransparency)
            if #available(iOS 14.5, *) {
                let status = ATTrackingManager.trackingAuthorizationStatus
                let isAuthorized = status == .authorized
                Settings.shared.isAdvertiserTrackingEnabled = isAuthorized
                Settings.shared.isAdvertiserIDCollectionEnabled = isAuthorized

                // Capture IDFA when authorized for improved Event Match Quality
                if isAuthorized {
                    _ = self?.captureIDFA()
                } else {
                    self?.clearIDFA()
                }

                debugLog("Meta ATT status updated: \(isAuthorized ? "authorized" : "not authorized") (status: \(status.rawValue))")
            } else {
                // Pre-iOS 14.5, tracking is allowed by default
                Settings.shared.isAdvertiserTrackingEnabled = true
                Settings.shared.isAdvertiserIDCollectionEnabled = true
                _ = self?.captureIDFA()
                debugLog("Meta tracking enabled (pre-iOS 14.5)")
            }
            #else
            // ATT not available, enable tracking
            Settings.shared.isAdvertiserTrackingEnabled = true
            Settings.shared.isAdvertiserIDCollectionEnabled = true
            #endif
            #else
            // Non-iOS platform, enable tracking
            Settings.shared.isAdvertiserTrackingEnabled = true
            Settings.shared.isAdvertiserIDCollectionEnabled = true
            #endif
        }
        #endif
    }

    /// Check if ATT is authorized
    func isTrackingAuthorized() -> Bool {
        #if os(iOS)
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14.5, *) {
            return ATTrackingManager.trackingAuthorizationStatus == .authorized
        }
        #endif
        #endif
        return true // Pre-iOS 14.5 or non-iOS, tracking allowed
    }

    /// Get current ATT status
    func getTrackingAuthorizationStatus() -> UInt {
        #if os(iOS)
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14.5, *) {
            return ATTrackingManager.trackingAuthorizationStatus.rawValue
        }
        #endif
        #endif
        return 3 // .authorized equivalent for pre-iOS 14.5 or non-iOS
    }

    // MARK: - IDFA Capture

    /// Capture IDFA if ATT is authorized
    /// Returns the IDFA string or nil if not available/authorized
    func captureIDFA() -> String? {
        #if os(iOS)
        #if canImport(AdSupport)
        // Check ATT authorization first
        guard isTrackingAuthorized() else {
            debugLog("IDFA not captured - ATT not authorized")
            return nil
        }

        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString

        // Check for zeroed IDFA (indicates tracking disabled or not authorized)
        guard idfa != MetaIntegration.zeroUUID else {
            debugLog("IDFA is zeroed - tracking not available")
            return nil
        }

        cachedIDFA = idfa
        debugLog("IDFA captured: \(idfa)")
        return idfa
        #else
        return nil
        #endif
        #else
        return nil
        #endif
    }

    /// Get cached IDFA (previously captured)
    /// Does not attempt to recapture - use captureIDFA() for that
    func getCachedIDFA() -> String? {
        return cachedIDFA
    }

    /// Get IDFA, capturing if not already cached and ATT authorized
    func getIDFA() -> String? {
        if let cached = cachedIDFA {
            return cached
        }
        return captureIDFA()
    }

    /// Clear cached IDFA (call on logout or when ATT revoked)
    func clearIDFA() {
        cachedIDFA = nil
        debugLog("IDFA cache cleared")
    }

    /// Get advertising identifier data for server-side CAPI
    /// Returns dictionary with idfa and att_status for inclusion in events
    func getAdvertiserData() -> [String: Any] {
        var data: [String: Any] = [:]

        // Include ATT status
        data["att_status"] = getTrackingAuthorizationStatus()
        data["tracking_authorized"] = isTrackingAuthorized()

        // Include IDFA if available
        if let idfa = getIDFA() {
            data["idfa"] = idfa
        }

        #if os(iOS)
        #if canImport(AdSupport)
        // Include whether advertising tracking is enabled at system level
        data["advertising_tracking_enabled"] = ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        #endif
        #endif

        return data
    }

    /// Fetch deferred app link from Meta
    /// This captures fbclid for installs that went through App Store
    func fetchDeferredAppLink() async -> DeferredDeepLinkResult? {
        #if canImport(FBSDKCoreKit)
        guard isInitialized else {
            errorLog("Meta SDK not initialized")
            return nil
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                AppLinkUtility.fetchDeferredAppLink { url, error in
                    if let error = error {
                        errorLog("Meta deferred app link fetch failed: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                        return
                    }

                    guard let url = url else {
                        debugLog("No deferred app link available from Meta")
                        continuation.resume(returning: nil)
                        return
                    }

                    // Extract attribution parameters from URL
                    let result = self.parseDeepLinkUrl(url)
                    debugLog("Meta deferred app link fetched: \(url.absoluteString)")
                    continuation.resume(returning: result)
                }
            }
        }
        #else
        return nil
        #endif
    }

    /// Parse deep link URL for attribution parameters
    private func parseDeepLinkUrl(_ url: URL) -> DeferredDeepLinkResult {
        var result = DeferredDeepLinkResult()
        result.url = url.absoluteString
        result.source = "meta"

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return result
        }

        // Extract query parameters
        if let queryItems = components.queryItems {
            for item in queryItems {
                switch item.name.lowercased() {
                case "fbclid":
                    result.fbclid = item.value
                case "utm_source":
                    result.utmSource = item.value
                case "utm_medium":
                    result.utmMedium = item.value
                case "utm_campaign":
                    result.utmCampaign = item.value
                case "utm_content":
                    result.utmContent = item.value
                case "utm_term":
                    result.utmTerm = item.value
                case "campaign_id":
                    result.campaignId = item.value
                case "adset_id":
                    result.adsetId = item.value
                case "ad_id":
                    result.adId = item.value
                default:
                    break
                }
            }
        }

        return result
    }

    /// Log purchase event to Meta
    func logPurchase(value: Double, currency: String, parameters: [String: Any]? = nil) {
        #if canImport(FBSDKCoreKit)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            var eventParams: [AppEvents.ParameterName: Any] = [:]

            // Add custom parameters
            if let parameters = parameters {
                for (key, value) in parameters {
                    eventParams[AppEvents.ParameterName(key)] = value
                }
            }

            AppEvents.shared.logPurchase(amount: value, currency: currency, parameters: eventParams)
            debugLog("Meta purchase event logged: \(value) \(currency)")
        }
        #endif
    }

    /// Log custom event to Meta
    func logEvent(name: String, parameters: [String: Any]? = nil, valueToSum: Double? = nil) {
        #if canImport(FBSDKCoreKit)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let eventName = AppEvents.Name(name)
            var eventParams: [AppEvents.ParameterName: Any] = [:]

            if let parameters = parameters {
                for (key, value) in parameters {
                    eventParams[AppEvents.ParameterName(key)] = value
                }
            }

            if let valueToSum = valueToSum {
                AppEvents.shared.logEvent(eventName, valueToSum: valueToSum, parameters: eventParams)
            } else {
                AppEvents.shared.logEvent(eventName, parameters: eventParams)
            }

            debugLog("Meta event logged: \(name)")
        }
        #endif
    }

    /// Log app install event
    func logInstall() {
        #if canImport(FBSDKCoreKit)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            // Meta SDK automatically tracks installs, but we can log a custom event
            AppEvents.shared.logEvent(AppEvents.Name("DatalyrInstall"))
            debugLog("Meta install event logged")
        }
        #endif
    }

    /// Set user data for Advanced Matching (improves conversion attribution)
    func setUserData(
        email: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        phone: String? = nil,
        dateOfBirth: String? = nil,
        gender: String? = nil,
        city: String? = nil,
        state: String? = nil,
        zip: String? = nil,
        country: String? = nil
    ) {
        #if canImport(FBSDKCoreKit)
        guard isInitialized else { return }

        DispatchQueue.main.async {
            // Set user data for Advanced Matching
            AppEvents.shared.setUserData(
                email,
                forType: .email
            )
            if let firstName = firstName {
                AppEvents.shared.setUserData(firstName, forType: .firstName)
            }
            if let lastName = lastName {
                AppEvents.shared.setUserData(lastName, forType: .lastName)
            }
            if let phone = phone {
                AppEvents.shared.setUserData(phone, forType: .phone)
            }
            if let dateOfBirth = dateOfBirth {
                AppEvents.shared.setUserData(dateOfBirth, forType: .dateOfBirth)
            }
            if let gender = gender {
                AppEvents.shared.setUserData(gender, forType: .gender)
            }
            if let city = city {
                AppEvents.shared.setUserData(city, forType: .city)
            }
            if let state = state {
                AppEvents.shared.setUserData(state, forType: .state)
            }
            if let zip = zip {
                AppEvents.shared.setUserData(zip, forType: .zip)
            }
            if let country = country {
                AppEvents.shared.setUserData(country, forType: .country)
            }

            debugLog("Meta user data set for Advanced Matching")
        }
        #endif
    }

    /// Clear user data (call on logout)
    func clearUserData() {
        #if canImport(FBSDKCoreKit)
        guard isInitialized else { return }

        DispatchQueue.main.async {
            AppEvents.shared.clearUserData()
            debugLog("Meta user data cleared")
        }
        #endif
    }

    /// Check if Meta SDK is available and initialized
    func isAvailable() -> Bool {
        #if canImport(FBSDKCoreKit)
        return isInitialized
        #else
        return false
        #endif
    }
}
