import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(TikTokBusinessSDK)
import TikTokBusinessSDK
#endif

/// Manages TikTok Business SDK integration for attribution and event forwarding
internal class TikTokIntegration {
    private var isInitialized = false
    private let eventsAppId: String      // Events API App ID (from TikTok Events Manager)
    private let tiktokAppId: String      // TikTok App ID (from TikTok Developer Portal)
    private let accessToken: String?
    private let enableAttribution: Bool
    private let forwardEvents: Bool
    private let debug: Bool

    init(eventsAppId: String, tiktokAppId: String, accessToken: String?, enableAttribution: Bool, forwardEvents: Bool, debug: Bool) {
        self.eventsAppId = eventsAppId
        self.tiktokAppId = tiktokAppId
        self.accessToken = accessToken
        self.enableAttribution = enableAttribution
        self.forwardEvents = forwardEvents
        self.debug = debug
    }

    /// Initialize TikTok Business SDK
    func initialize() async {
        #if canImport(TikTokBusinessSDK)
        await MainActor.run {
            // Configure TikTok SDK with correct App IDs
            let config = TikTokConfig(appId: eventsAppId, tiktokAppId: tiktokAppId)
            config?.setLogLevel(debug ? .debug : .none)

            // Set tracking based on ATT status
            let trackingDisabled = !isTrackingAuthorized()
            config?.disableTracking = trackingDisabled
            config?.disableAutomaticTracking = trackingDisabled

            if let accessToken = accessToken {
                config?.accessToken = accessToken
            }

            // Initialize the SDK
            TikTokBusiness.initializeSdk(config)

            isInitialized = true
            debugLog("TikTok SDK initialized with Events App ID: \(eventsAppId), TikTok App ID: \(tiktokAppId), tracking: \(trackingDisabled ? "disabled" : "enabled")")
        }
        #else
        debugLog("TikTok SDK not available - TikTokBusinessSDK not imported")
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

    /// Update tracking status after ATT prompt
    /// Note: TikTok SDK doesn't have a runtime update method, but we track the event
    func updateTrackingAuthorization() {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized else { return }

        let isAuthorized = isTrackingAuthorized()
        debugLog("TikTok ATT status: \(isAuthorized ? "authorized" : "not authorized")")

        // Log ATT status as an event for TikTok's attribution
        if isAuthorized {
            DispatchQueue.main.async {
                TikTokBusiness.trackEvent("ATTAuthorized")
            }
        }
        #endif
    }

    /// Get TikTok attribution data
    /// Note: TikTok deferred deep linking is not fully supported yet,
    /// but we can capture data from the SDK's automatic tracking
    func getAttributionData() -> DeferredDeepLinkResult? {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized else {
            errorLog("TikTok SDK not initialized")
            return nil
        }

        // TikTok SDK automatically captures ttclid if available
        // We can extract it from the launch URL if the app was opened via deep link
        var result = DeferredDeepLinkResult()
        result.source = "tiktok"

        // Note: The TikTok Business SDK doesn't expose deferred deep link data directly
        // Attribution is handled server-side by TikTok when events are sent

        return result
        #else
        return nil
        #endif
    }

    // MARK: - Event Tracking (using modern TikTokBaseEvent API)

    /// Log purchase event to TikTok
    func logPurchase(value: Double, currency: String, contentId: String? = nil, contentType: String? = nil, parameters: [String: Any]? = nil) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "Purchase")
            event.addProperty(withKey: "value", value: value)
            event.addProperty(withKey: "currency", value: currency)

            if let contentId = contentId {
                event.addProperty(withKey: "content_id", value: contentId)
            }
            if let contentType = contentType {
                event.addProperty(withKey: "content_type", value: contentType)
            }

            if let parameters = parameters {
                for (key, val) in parameters {
                    event.addProperty(withKey: key, value: val)
                }
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok Purchase event logged: \(value) \(currency)")
        }
        #endif
    }

    /// Log custom event to TikTok
    func logEvent(name: String, properties: [String: Any]? = nil) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: name)

            if let properties = properties {
                for (key, val) in properties {
                    event.addProperty(withKey: key, value: val)
                }
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok event logged: \(name)")
        }
        #endif
    }

    /// Log subscription event to TikTok
    func logSubscription(value: Double, currency: String, plan: String?) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "Subscribe")
            event.addProperty(withKey: "value", value: value)
            event.addProperty(withKey: "currency", value: currency)

            if let plan = plan {
                event.addProperty(withKey: "content_id", value: plan)
                event.addProperty(withKey: "content_type", value: "subscription")
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok subscription event logged: \(value) \(currency)")
        }
        #endif
    }

    /// Log add to cart event
    func logAddToCart(value: Double, currency: String, contentId: String?, contentType: String?) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "AddToCart")
            event.addProperty(withKey: "value", value: value)
            event.addProperty(withKey: "currency", value: currency)

            if let contentId = contentId {
                event.addProperty(withKey: "content_id", value: contentId)
            }
            if let contentType = contentType {
                event.addProperty(withKey: "content_type", value: contentType)
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok add to cart event logged")
        }
        #endif
    }

    /// Log view content event
    func logViewContent(contentId: String?, contentName: String?, contentType: String?, value: Double?, currency: String?) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "ViewContent")

            if let contentId = contentId {
                event.addProperty(withKey: "content_id", value: contentId)
            }
            if let contentName = contentName {
                event.addProperty(withKey: "content_name", value: contentName)
            }
            if let contentType = contentType {
                event.addProperty(withKey: "content_type", value: contentType)
            }
            if let value = value {
                event.addProperty(withKey: "value", value: value)
            }
            if let currency = currency {
                event.addProperty(withKey: "currency", value: currency)
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok view content event logged")
        }
        #endif
    }

    /// Log initiate checkout event
    func logInitiateCheckout(value: Double, currency: String, numItems: Int?, contentIds: [String]?) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "InitiateCheckout")
            event.addProperty(withKey: "value", value: value)
            event.addProperty(withKey: "currency", value: currency)

            if let numItems = numItems {
                event.addProperty(withKey: "quantity", value: numItems)
            }
            if let contentIds = contentIds {
                event.addProperty(withKey: "content_ids", value: contentIds)
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok initiate checkout event logged")
        }
        #endif
    }

    /// Log complete registration event
    func logCompleteRegistration(method: String?) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "CompleteRegistration")

            if let method = method {
                event.addProperty(withKey: "registration_method", value: method)
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok complete registration event logged")
        }
        #endif
    }

    /// Log search event
    func logSearch(query: String, contentIds: [String]?) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "Search")
            event.addProperty(withKey: "query", value: query)

            if let contentIds = contentIds {
                event.addProperty(withKey: "content_ids", value: contentIds)
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok search event logged")
        }
        #endif
    }

    /// Log lead event
    func logLead(value: Double?, currency: String?) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "SubmitForm")

            if let value = value {
                event.addProperty(withKey: "value", value: value)
            }
            if let currency = currency {
                event.addProperty(withKey: "currency", value: currency)
            }

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok lead event logged")
        }
        #endif
    }

    /// Log add payment info event
    func logAddPaymentInfo(success: Bool) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized && forwardEvents else { return }

        DispatchQueue.main.async {
            let event = TikTokBaseEvent(eventName: "AddPaymentInfo")
            event.addProperty(withKey: "success", value: success)

            TikTokBusiness.trackTTEvent(event)
            debugLog("TikTok add payment info event logged")
        }
        #endif
    }

    // MARK: - User Identification

    /// Identify user (for improved attribution matching)
    func identify(email: String?, phone: String?, externalId: String?, externalUserName: String? = nil) {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized else { return }

        DispatchQueue.main.async {
            // Use the modern identify method with all parameters
            TikTokBusiness.identify(
                withExternalID: externalId,
                externalUserName: externalUserName,
                phoneNumber: phone,
                email: email
            )
            debugLog("TikTok user identification set")
        }
        #endif
    }

    /// Logout and clear user data
    func logout() {
        #if canImport(TikTokBusinessSDK)
        guard isInitialized else { return }

        DispatchQueue.main.async {
            TikTokBusiness.logout()
            debugLog("TikTok user logged out")
        }
        #endif
    }

    /// Check if TikTok SDK is available and initialized
    func isAvailable() -> Bool {
        #if canImport(TikTokBusinessSDK)
        return isInitialized
        #else
        return false
        #endif
    }
}
