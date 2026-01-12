import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

// MARK: - Main SDK Class

/// Main Datalyr SDK class providing analytics tracking functionality
public class DatalyrSDK {
    
    // MARK: - Singleton
    
    /// Shared singleton instance
    public static let shared = DatalyrSDK()
    
    // MARK: - Public Properties

    /// Delegate for receiving SDK callbacks (errors, attribution, conversion updates)
    public weak var delegate: DatalyrSDKDelegate?

    // MARK: - Private Properties

    private var initialized = false
    internal var config: DatalyrConfig?
    private var httpClient: DatalyrHTTPClient?
    private var eventQueue: DatalyrEventQueue?
    private var attributionManager: AttributionManager?
    private var autoEventsManager: AutoEventsManager?
    
    // Session and user data
    private var visitorId: String = ""
    private var anonymousId: String = ""  // Persistent anonymous identifier
    private var sessionId: String = ""
    private var currentUserId: String?
    private var userProperties: UserProperties = [:]
    
    // SKAdNetwork conversion value encoder
    private var conversionEncoder: ConversionValueEncoder?

    // Platform SDK integrations (Meta, TikTok)
    private var platformIntegrationManager: PlatformIntegrationManager?

    // App lifecycle monitoring
    private var appStateObserver: NSObjectProtocol?
    #if canImport(UIKit)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    private init() {
        setupNotificationObservers()
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Public API
    
    /// Initialize the Datalyr SDK
    /// - Parameter config: SDK configuration
    /// - Throws: Initialization errors
    public func initialize(config: DatalyrConfig) async throws {
        guard !initialized else {
            debugLog("SDK already initialized")
            return
        }
        
        debugLog("Initializing Datalyr SDK...", data: ["workspaceId": config.workspaceId])
        
        // Validate configuration
        guard !config.apiKey.isEmpty else {
            throw DatalyrError.invalidConfiguration("apiKey is required for Datalyr SDK v1.0.0")
        }
        
        // workspaceId is now optional (for backward compatibility)
        if config.workspaceId.isEmpty {
            debugLog("workspaceId not provided, using server-side tracking only")
        }
        
        // Store configuration
        self.config = config
        
        // Initialize HTTP client with server-side API
        let httpConfig = HTTPClientConfig(
            maxRetries: config.maxRetries,
            retryDelay: config.retryDelay,
            timeout: config.timeout,
            apiKey: config.apiKey,
            workspaceId: config.workspaceId.isEmpty ? nil : config.workspaceId,
            useServerTracking: config.useServerTracking,
            debug: config.debug
        )
        self.httpClient = DatalyrHTTPClient(endpoint: config.endpoint.isEmpty ? "https://api.datalyr.com" : config.endpoint, config: httpConfig)
        
        // Initialize event queue
        let queueConfig = QueueConfig(
            maxQueueSize: config.maxQueueSize,
            batchSize: config.batchSize,
            flushInterval: config.flushInterval,
            maxRetryCount: config.maxRetries
        )
        self.eventQueue = DatalyrEventQueue(httpClient: httpClient!, config: queueConfig)
        
        // Initialize visitor ID, anonymous ID and session
        self.visitorId = await getOrCreateVisitorId()
        self.anonymousId = await getOrCreateAnonymousId()
        self.sessionId = await getOrCreateSessionId()
        
        // Load persisted user data
        await loadPersistedUserData()
        
        // Initialize attribution manager
        if config.enableAttribution {
            self.attributionManager = AttributionManager()
            await attributionManager?.initialize()
        }

        // Initialize journey tracking (for first-touch, last-touch, touchpoints)
        await JourneyManager.shared.initialize()

        // Record initial attribution to journey if this is a new session with attribution
        if let attribution = attributionManager?.getAttributionData() {
            let hasAttribution = attribution.utmSource != nil ||
                                attribution.fbclid != nil ||
                                attribution.gclid != nil ||
                                attribution.lyr != nil

            if hasAttribution {
                var touchAttribution = TouchAttribution(
                    timestamp: 0,
                    expiresAt: 0,
                    capturedAt: 0
                )
                touchAttribution.source = attribution.utmSource ?? attribution.campaignSource
                touchAttribution.medium = attribution.utmMedium ?? attribution.campaignMedium
                touchAttribution.campaign = attribution.utmCampaign ?? attribution.campaignName
                touchAttribution.fbclid = attribution.fbclid
                touchAttribution.gclid = attribution.gclid
                touchAttribution.ttclid = attribution.ttclid
                touchAttribution.lyr = attribution.lyr
                if attribution.fbclid != nil {
                    touchAttribution.clickIdType = "fbclid"
                } else if attribution.gclid != nil {
                    touchAttribution.clickIdType = "gclid"
                } else if attribution.ttclid != nil {
                    touchAttribution.clickIdType = "ttclid"
                }

                await JourneyManager.shared.recordAttribution(sessionId: sessionId, attribution: touchAttribution)
            }
        }

        // Initialize auto-events manager
        if config.enableAutoEvents {
            self.autoEventsManager = AutoEventsManager(
                trackingDelegate: self,
                config: config.autoEventConfig ?? AutoEventConfig()
            )
            await autoEventsManager?.initialize()
        }
        
        // Initialize SKAdNetwork conversion encoder
        if let templateName = config.skadTemplate {
            let template: ConversionTemplate
            switch templateName.lowercased() {
            case "gaming":
                template = .gaming
            case "subscription":
                template = .subscription
            default:
                template = .ecommerce
            }

            self.conversionEncoder = ConversionValueEncoder(template: template)

            if config.debug {
                debugLog("SKAdNetwork encoder initialized with template: \(templateName)")
            }
        }

        // Initialize platform SDK integrations (Meta, TikTok)
        if config.metaAppId != nil || config.tiktokAppId != nil {
            self.platformIntegrationManager = PlatformIntegrationManager()
            await platformIntegrationManager?.initialize(config: config)

            // Fetch deferred deep link attribution on first launch
            if config.enableAttribution {
                if let deferredData = await platformIntegrationManager?.fetchDeferredAttribution() {
                    await mergeDeferredAttribution(deferredData)
                }
            }
        }

        // Mark as initialized
        self.initialized = true

        // Check for app install (after SDK is marked as initialized)
        await checkAndTrackInstall()

        // Register for attribution tracking (AdAttributionKit on iOS 17.4+, SKAdNetwork otherwise)
        await UnifiedAttributionTracker.shared.register()

        debugLog("Datalyr SDK initialized successfully", data: [
            "workspaceId": config.workspaceId,
            "visitorId": visitorId,
            "anonymousId": anonymousId,
            "sessionId": sessionId
        ])

        // Notify delegate
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.datalyrDidInitialize()
        }
    }

    // MARK: - Delegate Notification Helpers

    /// Notify delegate of a platform error on the main thread
    internal func notifyDelegateOfError(_ error: DatalyrPlatformError, eventName: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.datalyrDidFailToSendEvent(error, eventName: eventName)
        }
    }

    /// Notify delegate of attribution data on the main thread
    internal func notifyDelegateOfAttribution(_ attribution: AttributionData) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.datalyrDidReceiveAttribution(attribution)
        }
    }

    /// Notify delegate of conversion value update on the main thread
    internal func notifyDelegateOfConversionUpdate(fineValue: Int, coarseValue: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.datalyrDidUpdateConversionValue(fineValue: fineValue, coarseValue: coarseValue)
        }
    }
    
    /// Track a custom event
    /// - Parameters:
    ///   - eventName: Name of the event
    ///   - eventData: Optional event properties
    public func track(_ eventName: String, eventData: EventData? = nil) async {
        guard initialized else {
            errorLog("SDK not initialized. Call initialize() first.")
            return
        }
        
        guard validateEventName(eventName) else {
            errorLog("Invalid event name: \(eventName)")
            return
        }
        
        guard validateEventData(eventData) else {
            errorLog("Invalid event data provided")
            return
        }
        
        debugLog("Tracking event: \(eventName)", data: eventData)
        
        do {
            let payload = await createEventPayload(eventName: eventName, eventData: eventData)
            await eventQueue?.enqueue(payload)
        } catch {
            errorLog("Error tracking event \(eventName)", error: error)
        }
    }
    
    /// Track a screen view
    /// - Parameters:
    ///   - screenName: Name of the screen
    ///   - properties: Optional screen properties
    public func screen(_ screenName: String, properties: EventData? = nil) async {
        var screenData: EventData = ["screen": screenName]
        
        if let properties = properties {
            screenData.merge(properties) { (_, new) in new }
        }
        
        await track("pageview", eventData: screenData)
    }
    
    /// Identify a user
    /// - Parameters:
    ///   - userId: User identifier
    ///   - properties: Optional user properties
    public func identify(_ userId: String, properties: UserProperties? = nil) async {
        guard initialized else {
            errorLog("SDK not initialized. Call initialize() first.")
            return
        }

        debugLog("Identifying user: \(userId)", data: properties)

        // Update current user
        currentUserId = userId

        if let properties = properties {
            userProperties.merge(properties) { (_, new) in new }
        }

        // Persist user data
        await persistUserData()

        // Track $identify event for identity resolution
        await track("$identify", eventData: [
            "user_id": userId,
            "anonymous_id": anonymousId,
            "properties": properties ?? [:]
        ])

        // Fetch and merge web attribution if email is provided
        let emailForAttribution = properties?["email"] as? String ?? (userId.contains("@") ? userId : nil)
        if let email = emailForAttribution {
            await fetchAndMergeWebAttribution(email: email)
        }

        // Identify user on platform SDKs for improved attribution matching (Advanced Matching)
        // Extract all available user properties for better match rates
        let email = properties?["email"] as? String
        let phone = properties?["phone"] as? String
        let firstName = properties?["first_name"] as? String ?? properties?["firstName"] as? String
        let lastName = properties?["last_name"] as? String ?? properties?["lastName"] as? String
        let dateOfBirth = properties?["date_of_birth"] as? String ?? properties?["dob"] as? String ?? properties?["birthday"] as? String
        let gender = properties?["gender"] as? String
        let city = properties?["city"] as? String
        let state = properties?["state"] as? String
        let zip = properties?["zip"] as? String ?? properties?["postal_code"] as? String ?? properties?["zipcode"] as? String
        let country = properties?["country"] as? String

        platformIntegrationManager?.identifyUser(
            userId: userId,
            email: email,
            phone: phone,
            firstName: firstName,
            lastName: lastName,
            dateOfBirth: dateOfBirth,
            gender: gender,
            city: city,
            state: state,
            zip: zip,
            country: country
        )
    }

    /// Fetch web attribution data for user and merge into mobile session
    /// Called automatically during identify() if email is provided
    private func fetchAndMergeWebAttribution(email: String) async {
        guard let apiKey = config?.apiKey else {
            debugLog("API key not available for web attribution fetch")
            return
        }

        debugLog("Fetching web attribution for email: \(email)")

        guard let url = URL(string: "https://api.datalyr.com/attribution/lookup") else {
            errorLog("Invalid attribution API URL")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-Datalyr-API-Key")

            let body = ["email": email]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                errorLog("Invalid response from attribution API")
                return
            }

            if httpResponse.statusCode != 200 {
                debugLog("Failed to fetch web attribution: \(httpResponse.statusCode)")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let found = json["found"] as? Bool,
                  found,
                  let attribution = json["attribution"] as? [String: Any] else {
                debugLog("No web attribution found for user")
                return
            }

            debugLog("Web attribution found", data: [
                "visitor_id": attribution["visitor_id"] ?? "",
                "has_fbclid": attribution["fbclid"] != nil,
                "has_gclid": attribution["gclid"] != nil,
                "utm_source": attribution["utm_source"] ?? ""
            ])

            // Merge web attribution into current session
            var mergedData: [String: Any] = [
                "web_visitor_id": attribution["visitor_id"] ?? "",
                "web_user_id": attribution["user_id"] ?? ""
            ]

            // Add click IDs
            if let fbclid = attribution["fbclid"] { mergedData["fbclid"] = fbclid }
            if let gclid = attribution["gclid"] { mergedData["gclid"] = gclid }
            if let ttclid = attribution["ttclid"] { mergedData["ttclid"] = ttclid }
            if let gbraid = attribution["gbraid"] { mergedData["gbraid"] = gbraid }
            if let wbraid = attribution["wbraid"] { mergedData["wbraid"] = wbraid }
            if let fbp = attribution["fbp"] { mergedData["fbp"] = fbp }
            if let fbc = attribution["fbc"] { mergedData["fbc"] = fbc }

            // Add UTM parameters
            if let utmSource = attribution["utm_source"] { mergedData["utm_source"] = utmSource }
            if let utmMedium = attribution["utm_medium"] { mergedData["utm_medium"] = utmMedium }
            if let utmCampaign = attribution["utm_campaign"] { mergedData["utm_campaign"] = utmCampaign }
            if let utmContent = attribution["utm_content"] { mergedData["utm_content"] = utmContent }
            if let utmTerm = attribution["utm_term"] { mergedData["utm_term"] = utmTerm }
            if let timestamp = attribution["timestamp"] { mergedData["web_timestamp"] = timestamp }

            await track("$web_attribution_merged", eventData: mergedData)

            // Update attribution manager with web data
            await attributionManager?.mergeWebAttribution(attribution)

            debugLog("Successfully merged web attribution into mobile session")

        } catch {
            errorLog("Error fetching web attribution: \(error.localizedDescription)")
            // Non-blocking - continue even if attribution fetch fails
        }
    }
    
    /// Create an alias for the current user
    /// - Parameters:
    ///   - newUserId: New user identifier
    ///   - previousId: Previous user identifier (optional)
    public func alias(_ newUserId: String, previousId: String? = nil) async {
        guard initialized else {
            errorLog("SDK not initialized. Call initialize() first.")
            return
        }
        
        let previousUserId = previousId ?? currentUserId ?? visitorId
        
        debugLog("Creating alias: \(newUserId) for \(previousUserId)")
        
        // Track alias event with anonymous_id for identity resolution
        await track("alias", eventData: [
            "user_id": newUserId,
            "previous_id": previousUserId,
            "anonymous_id": anonymousId
        ])
        
        // Update current user
        currentUserId = newUserId
        await persistUserData()
    }
    
    /// Reset the current user session
    public func reset() async {
        guard initialized else {
            errorLog("SDK not initialized. Call initialize() first.")
            return
        }
        
        debugLog("Resetting user session")
        
        // Clear user data
        currentUserId = nil
        userProperties.removeAll()
        
        // Generate new visitor and session IDs
        visitorId = generateUUID()
        sessionId = await refreshSessionId()
        
        // Clear stored user data
        await DatalyrStorage.shared.removeValue(StorageKeys.userId)
        await DatalyrStorage.shared.removeValue(StorageKeys.userProperties)
        await DatalyrStorage.shared.setString(StorageKeys.visitorId, value: visitorId)
        
        // Clear attribution data
        await attributionManager?.clearAttributionData()

        // Clear user data from platform SDKs
        platformIntegrationManager?.clearUserData()

        debugLog("User session reset complete")
    }
    
    /// Manually flush the event queue
    public func flush() async {
        guard initialized else {
            errorLog("SDK not initialized. Call initialize() first.")
            return
        }
        
        debugLog("Flushing event queue")
        await eventQueue?.flush()
    }
    
    /// Get current SDK status
    /// - Returns: SDK status information
    public func getStatus() -> SDKStatus {
        let queueStats = eventQueue?.getStats() ?? QueueStats(queueSize: 0, isProcessing: false, isOnline: true)
        let attribution = attributionManager?.getAttributionData() ?? AttributionData()
        
        return SDKStatus(
            initialized: initialized,
            workspaceId: config?.workspaceId ?? "",
            visitorId: visitorId,
            anonymousId: anonymousId,
            sessionId: sessionId,
            currentUserId: currentUserId,
            queueStats: queueStats,
            attribution: attribution
        )
    }
    
    /// Get current attribution data (includes journey tracking data)
    /// - Returns: Attribution data merged with journey tracking data
    public func getAttributionData() -> AttributionData {
        return attributionManager?.getAttributionData() ?? AttributionData()
    }

    /// Get journey tracking data (first-touch, last-touch, touchpoint count)
    /// - Returns: Dictionary with journey tracking data
    public func getJourneyData() -> [String: Any] {
        return JourneyManager.shared.getAttributionData()
    }

    /// Get journey tracking summary for debugging
    /// - Returns: Journey summary with key metrics
    public func getJourneySummary() -> JourneySummary {
        return JourneyManager.shared.getJourneySummary()
    }

    /// Get full customer journey (all touchpoints)
    /// - Returns: Array of touchpoints
    public func getJourney() -> [TouchPoint] {
        return JourneyManager.shared.getJourney()
    }

    /// Get the persistent anonymous ID
    /// - Returns: Anonymous identifier
    public func getAnonymousId() -> String {
        return anonymousId
    }

    /// Set attribution data manually
    /// - Parameter data: Attribution data to set
    public func setAttributionData(_ data: AttributionData) async {
        await attributionManager?.setAttributionData(data)
    }

    /// Get deferred deep link attribution data from platform SDKs (Meta, TikTok)
    /// - Returns: Deferred deep link result if available
    public func getDeferredAttributionData() -> DeferredDeepLinkResult? {
        return platformIntegrationManager?.getDeferredAttributionData()
    }

    /// Get Apple Search Ads attribution data
    /// - Returns: Apple Search Ads attribution if available
    public func getAppleSearchAdsAttribution() -> AppleSearchAdsAttribution? {
        return platformIntegrationManager?.getAppleSearchAdsAttribution()
    }

    /// Get platform integration status
    /// - Returns: Dictionary with platform availability status
    public func getPlatformIntegrationStatus() -> [String: Bool] {
        return [
            "meta": platformIntegrationManager?.isMetaAvailable() ?? false,
            "tiktok": platformIntegrationManager?.isTikTokAvailable() ?? false,
            "appleSearchAds": platformIntegrationManager?.isAppleSearchAdsAvailable() ?? false
        ]
    }

    // MARK: - App Tracking Transparency (ATT)

    /// Update tracking authorization status on all platform SDKs
    /// Call this AFTER the user responds to the ATT permission dialog
    ///
    /// Example usage:
    /// ```swift
    /// ATTrackingManager.requestTrackingAuthorization { status in
    ///     Task {
    ///         await DatalyrSDK.shared.updateTrackingAuthorization(status: status)
    ///     }
    /// }
    /// ```
    public func updateTrackingAuthorization(status: UInt? = nil) async {
        guard initialized else {
            errorLog("SDK not initialized. Call initialize() first.")
            return
        }

        platformIntegrationManager?.updateTrackingAuthorization()

        // Track ATT status event
        let attStatus = status ?? (platformIntegrationManager?.getTrackingAuthorizationStatus() ?? 0)
        let statusName: String
        switch attStatus {
        case 0: statusName = "notDetermined"
        case 1: statusName = "restricted"
        case 2: statusName = "denied"
        case 3: statusName = "authorized"
        default: statusName = "unknown"
        }

        await track("$att_status", eventData: [
            "status": attStatus,
            "status_name": statusName,
            "authorized": attStatus == 3
        ])

        debugLog("ATT status updated: \(statusName) (\(attStatus))")
    }

    /// Check if App Tracking Transparency is authorized
    /// - Returns: true if ATT is authorized or not required (pre-iOS 14.5)
    public func isTrackingAuthorized() -> Bool {
        return platformIntegrationManager?.isTrackingAuthorized() ?? true
    }

    /// Get current ATT authorization status
    /// - Returns: 0 = notDetermined, 1 = restricted, 2 = denied, 3 = authorized
    public func getTrackingAuthorizationStatus() -> UInt {
        return platformIntegrationManager?.getTrackingAuthorizationStatus() ?? 3
    }

    /// Request ATT permission and update platform SDKs
    /// Convenience method that handles the full ATT flow
    ///
    /// - Returns: The ATT authorization status after user response
    #if os(iOS)
    @available(iOS 14.5, *)
    public func requestTrackingAuthorization() async -> UInt {
        #if canImport(AppTrackingTransparency)
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                ATTrackingManager.requestTrackingAuthorization { status in
                    Task {
                        await self.updateTrackingAuthorization(status: status.rawValue)
                        continuation.resume(returning: status.rawValue)
                    }
                }
            }
        }
        #else
        return 3 // authorized
        #endif
    }

    /// Static convenience method for requesting ATT
    @available(iOS 14.5, *)
    public static func requestTrackingAuthorization() async -> UInt {
        return await shared.requestTrackingAuthorization()
    }
    #endif

    // MARK: - IDFA Access

    /// Get the IDFA (Identifier for Advertisers) if ATT is authorized
    /// - Returns: IDFA string or nil if not authorized/available
    public func getIDFA() -> String? {
        return platformIntegrationManager?.getIDFA()
    }

    /// Static convenience method to get IDFA
    public static func getIDFA() -> String? {
        return shared.getIDFA()
    }

    /// Get advertiser data dictionary for server-side API calls
    /// Contains: idfa (if authorized), att_status, tracking_authorized
    public func getAdvertiserData() -> [String: Any] {
        return platformIntegrationManager?.getAdvertiserData() ?? [
            "att_status": getTrackingAuthorizationStatus(),
            "tracking_authorized": isTrackingAuthorized()
        ]
    }

    /// Static convenience method for advertiser data
    public static func getAdvertiserData() -> [String: Any] {
        return shared.getAdvertiserData()
    }

    // MARK: - App Update Tracking

    /// Track app update
    /// - Parameters:
    ///   - previousVersion: Previous app version
    ///   - currentVersion: Current app version
    public func trackAppUpdate(previousVersion: String, currentVersion: String) async {
        await track("app_update", eventData: [
            "previous_version": previousVersion,
            "current_version": currentVersion,
            "platform": "ios"
        ])
    }
    
    /// Track revenue event
    /// - Parameters:
    ///   - eventName: Name of the revenue event
    ///   - properties: Revenue properties (should include 'value' and 'currency')
    public func trackRevenue(_ eventName: String, properties: EventData? = nil) async {
        var revenueData = properties ?? [:]
        revenueData["event_type"] = "revenue"
        
        await track(eventName, eventData: revenueData)
    }
    
    // MARK: - SKAdNetwork Enhanced Methods
    
    /// Initialize Datalyr SDK with SKAdNetwork conversion value encoding
    /// - Parameters:
    ///   - config: SDK configuration
    ///   - template: SKAdNetwork conversion template ("ecommerce", "gaming", "subscription")
    public static func initializeWithSKAdNetwork(
        config: DatalyrConfig, 
        template: String = "ecommerce"
    ) async throws {
        // Create config with SKAdNetwork template
        let skadConfig = DatalyrConfig(
            apiKey: config.apiKey,
            workspaceId: config.workspaceId,
            debug: config.debug,
            endpoint: config.endpoint,
            maxRetries: config.maxRetries,
            retryDelay: config.retryDelay,
            timeout: config.timeout,
            batchSize: config.batchSize,
            flushInterval: config.flushInterval,
            maxQueueSize: config.maxQueueSize,
            respectDoNotTrack: config.respectDoNotTrack,
            enableAutoEvents: config.enableAutoEvents,
            enableAttribution: config.enableAttribution,
            autoEventConfig: config.autoEventConfig,
            skadTemplate: template
        )
        
        try await shared.initialize(config: skadConfig)
    }
    
    /// Track event with automatic SKAdNetwork conversion value encoding
    /// - Parameters:
    ///   - event: Event name
    ///   - eventData: Event properties
    public func trackWithSKAdNetwork(
        _ event: String, 
        eventData: EventData? = nil
    ) async {
        // Existing tracking (keep this exactly as-is)
        await track(event, eventData: eventData)

        // NEW: Automatic SKAdNetwork encoding with SKAN 4.0 support
        guard let encoder = conversionEncoder else {
            if config?.debug == true {
                debugLog("SKAdNetwork encoder not initialized. Pass skadTemplate in initialize() or use initializeWithSKAdNetwork()")
            }
            return
        }

        // Use SKAN 4.0 encoding to get fine value, coarse value, and lock window
        let result = encoder.encodeWithSKAN4(event: event, properties: eventData)

        if result.fineValue > 0 {
            #if os(iOS)
            // SKAN 4.0 (iOS 16.1+): Use new API with coarse value and lock window
            if #available(iOS 16.1, *) {
                let coarseValue: SKAdNetwork.CoarseConversionValue
                switch result.coarseValue {
                case "high": coarseValue = .high
                case "medium": coarseValue = .medium
                default: coarseValue = .low
                }

                SKAdNetwork.updatePostbackConversionValue(result.fineValue, coarseValue: coarseValue, lockWindow: result.lockWindow) { error in
                    if let error = error {
                        print("[DatalyrSDK] SKAdNetwork 4.0 update error: \(error.localizedDescription)")
                    } else if self.config?.debug == true {
                        print("[DatalyrSDK] SKAdNetwork 4.0 updated - fine: \(result.fineValue), coarse: \(result.coarseValue), lock: \(result.lockWindow) for event: \(event)")
                    }
                }

                if config?.debug == true {
                    debugLog("SKAdNetwork 4.0 conversion value updated - fine: \(result.fineValue), coarse: \(result.coarseValue), lock: \(result.lockWindow) for event: \(event)", data: eventData)
                }
            }
            // SKAN 3.0 (iOS 14.0-16.0): Use deprecated API
            else if #available(iOS 14.0, *) {
                SKAdNetwork.updateConversionValue(result.fineValue)

                if config?.debug == true {
                    debugLog("SKAdNetwork 3.0 conversion value updated: \(result.fineValue) for event: \(event)", data: eventData)
                }
            } else if config?.debug == true {
                debugLog("SKAdNetwork requires iOS 14.0+")
            }
            #else
            if config?.debug == true {
                debugLog("SKAdNetwork only available on iOS")
            }
            #endif
        } else if config?.debug == true {
            debugLog("No conversion value generated for event: \(event)")
        }
    }
    
    /// Track purchase with automatic revenue encoding
    /// - Parameters:
    ///   - value: Purchase value
    ///   - currency: Currency code (default: "USD")
    ///   - productId: Product identifier (optional)
    public func trackPurchase(
        value: Double,
        currency: String = "USD",
        productId: String? = nil
    ) async {
        var properties: EventData = [
            "revenue": value,
            "currency": currency
        ]
        if let productId = productId {
            properties["product_id"] = productId
        }

        await trackWithSKAdNetwork("purchase", eventData: properties)

        // Forward to Meta and TikTok
        platformIntegrationManager?.forwardPurchase(
            value: value,
            currency: currency,
            productId: productId,
            parameters: properties
        )
    }
    
    /// Track subscription with automatic revenue encoding
    /// - Parameters:
    ///   - value: Subscription value
    ///   - currency: Currency code (default: "USD")
    ///   - plan: Subscription plan (optional)
    public func trackSubscription(
        value: Double,
        currency: String = "USD",
        plan: String? = nil
    ) async {
        var properties: EventData = [
            "revenue": value,
            "currency": currency
        ]
        if let plan = plan {
            properties["plan"] = plan
        }

        await trackWithSKAdNetwork("subscribe", eventData: properties)

        // Forward to Meta and TikTok
        platformIntegrationManager?.forwardSubscription(
            value: value,
            currency: currency,
            plan: plan
        )
    }

    // MARK: - Standard E-commerce Events

    /// Track add to cart event
    /// - Parameters:
    ///   - value: Cart item value
    ///   - currency: Currency code (default: "USD")
    ///   - productId: Product identifier
    ///   - productName: Product name (optional)
    public func trackAddToCart(
        value: Double,
        currency: String = "USD",
        productId: String? = nil,
        productName: String? = nil
    ) async {
        var properties: EventData = [
            "value": value,
            "currency": currency
        ]
        if let productId = productId { properties["product_id"] = productId }
        if let productName = productName { properties["product_name"] = productName }

        await trackWithSKAdNetwork("add_to_cart", eventData: properties)

        platformIntegrationManager?.forwardAddToCart(
            value: value,
            currency: currency,
            productId: productId,
            productName: productName
        )
    }

    /// Track view content/product event
    /// - Parameters:
    ///   - contentId: Content or product ID
    ///   - contentName: Content or product name
    ///   - contentType: Type of content (default: "product")
    ///   - value: Value of the content (optional)
    ///   - currency: Currency code (optional)
    public func trackViewContent(
        contentId: String? = nil,
        contentName: String? = nil,
        contentType: String = "product",
        value: Double? = nil,
        currency: String? = nil
    ) async {
        var properties: EventData = ["content_type": contentType]
        if let contentId = contentId { properties["content_id"] = contentId }
        if let contentName = contentName { properties["content_name"] = contentName }
        if let value = value { properties["value"] = value }
        if let currency = currency { properties["currency"] = currency }

        await track("view_content", eventData: properties)

        platformIntegrationManager?.forwardViewContent(
            contentId: contentId,
            contentName: contentName,
            contentType: contentType,
            value: value,
            currency: currency
        )
    }

    /// Track initiate checkout event
    /// - Parameters:
    ///   - value: Checkout value
    ///   - currency: Currency code (default: "USD")
    ///   - numItems: Number of items in cart
    ///   - productIds: Array of product IDs in cart
    public func trackInitiateCheckout(
        value: Double,
        currency: String = "USD",
        numItems: Int? = nil,
        productIds: [String]? = nil
    ) async {
        var properties: EventData = [
            "value": value,
            "currency": currency
        ]
        if let numItems = numItems { properties["num_items"] = numItems }
        if let productIds = productIds { properties["product_ids"] = productIds }

        await trackWithSKAdNetwork("initiate_checkout", eventData: properties)

        platformIntegrationManager?.forwardInitiateCheckout(
            value: value,
            currency: currency,
            numItems: numItems,
            contentIds: productIds
        )
    }

    /// Track complete registration event
    /// - Parameter method: Registration method (e.g., "email", "facebook", "google")
    public func trackCompleteRegistration(method: String? = nil) async {
        var properties: EventData = [:]
        if let method = method { properties["method"] = method }

        await trackWithSKAdNetwork("complete_registration", eventData: properties)

        platformIntegrationManager?.forwardCompleteRegistration(method: method)
    }

    /// Track search event
    /// - Parameters:
    ///   - query: Search query string
    ///   - resultIds: Array of result product IDs (optional)
    public func trackSearch(query: String, resultIds: [String]? = nil) async {
        var properties: EventData = ["query": query]
        if let resultIds = resultIds { properties["result_ids"] = resultIds }

        await track("search", eventData: properties)

        platformIntegrationManager?.forwardSearch(query: query, contentIds: resultIds)
    }

    /// Track lead/contact form submission
    /// - Parameters:
    ///   - value: Lead value (optional)
    ///   - currency: Currency code (optional)
    public func trackLead(value: Double? = nil, currency: String? = nil) async {
        var properties: EventData = [:]
        if let value = value { properties["value"] = value }
        if let currency = currency { properties["currency"] = currency }

        await trackWithSKAdNetwork("lead", eventData: properties)

        platformIntegrationManager?.forwardLead(value: value, currency: currency)
    }

    /// Track add payment info event
    /// - Parameter success: Whether payment info was added successfully
    public func trackAddPaymentInfo(success: Bool = true) async {
        await track("add_payment_info", eventData: ["success": success])

        platformIntegrationManager?.forwardAddPaymentInfo(success: success)
    }

    // MARK: - Conversion Value

    /// Get current conversion value for testing
    /// - Parameters:
    ///   - event: Event name
    ///   - properties: Event properties
    /// - Returns: Conversion value (0-63) or nil if encoder not initialized
    public func getConversionValue(for event: String, properties: EventData? = nil) -> Int? {
        return conversionEncoder?.encode(event: event, properties: properties)
    }
    
    // MARK: - Static Convenience Methods
    
    /// Track event with automatic SKAdNetwork conversion value encoding (static)
    public static func trackWithSKAdNetwork(
        _ event: String,
        eventData: EventData? = nil
    ) async {
        await shared.trackWithSKAdNetwork(event, eventData: eventData)
    }
    
    /// Track purchase with automatic revenue encoding (static)
    public static func trackPurchase(
        value: Double,
        currency: String = "USD",
        productId: String? = nil
    ) async {
        await shared.trackPurchase(value: value, currency: currency, productId: productId)
    }
    
    /// Track subscription with automatic revenue encoding (static)
    public static func trackSubscription(
        value: Double,
        currency: String = "USD",
        plan: String? = nil
    ) async {
        await shared.trackSubscription(value: value, currency: currency, plan: plan)
    }

    /// Track add to cart (static)
    public static func trackAddToCart(
        value: Double,
        currency: String = "USD",
        productId: String? = nil,
        productName: String? = nil
    ) async {
        await shared.trackAddToCart(value: value, currency: currency, productId: productId, productName: productName)
    }

    /// Track view content (static)
    public static func trackViewContent(
        contentId: String? = nil,
        contentName: String? = nil,
        contentType: String = "product",
        value: Double? = nil,
        currency: String? = nil
    ) async {
        await shared.trackViewContent(contentId: contentId, contentName: contentName, contentType: contentType, value: value, currency: currency)
    }

    /// Track initiate checkout (static)
    public static func trackInitiateCheckout(
        value: Double,
        currency: String = "USD",
        numItems: Int? = nil,
        productIds: [String]? = nil
    ) async {
        await shared.trackInitiateCheckout(value: value, currency: currency, numItems: numItems, productIds: productIds)
    }

    /// Track complete registration (static)
    public static func trackCompleteRegistration(method: String? = nil) async {
        await shared.trackCompleteRegistration(method: method)
    }

    /// Track search (static)
    public static func trackSearch(query: String, resultIds: [String]? = nil) async {
        await shared.trackSearch(query: query, resultIds: resultIds)
    }

    /// Track lead (static)
    public static func trackLead(value: Double? = nil, currency: String? = nil) async {
        await shared.trackLead(value: value, currency: currency)
    }

    /// Track add payment info (static)
    public static func trackAddPaymentInfo(success: Bool = true) async {
        await shared.trackAddPaymentInfo(success: success)
    }

    /// Get conversion value for testing (static)
    public static func getConversionValue(for event: String, properties: EventData? = nil) -> Int? {
        return shared.getConversionValue(for: event, properties: properties)
    }
    
    // MARK: - Private Methods
    
    /// Create event payload from event data
    private func createEventPayload(eventName: String, eventData: EventData?) async -> EventPayload {
        let eventId = generateUUID()
        let timestamp = DateFormatter.iso8601.string(from: Date())
        let fingerprintData = await createFingerprintData()

        var enrichedEventData = eventData ?? [:]

        // Add standard properties
        enrichedEventData["platform"] = "ios"
        enrichedEventData["app_version"] = getAppVersion()
        enrichedEventData["app_build"] = getAppBuildNumber()
        enrichedEventData["anonymous_id"] = anonymousId  // Include for attribution
        #if canImport(UIKit)
        enrichedEventData["os_version"] = UIDevice.current.systemVersion
        #else
        enrichedEventData["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        enrichedEventData["sdk_version"] = "1.2.0"

        // Add Apple Search Ads attribution if available
        if let asaData = platformIntegrationManager?.getAppleSearchAdsData() {
            enrichedEventData.merge(asaData) { (_, new) in new }
        }

        // Add advertiser data (IDFA) for improved Event Match Quality
        // IDFA is only included when ATT is authorized
        if let advertiserData = platformIntegrationManager?.getAdvertiserData() {
            enrichedEventData["advertiser_data"] = advertiserData
            // Also include IDFA at root level for backwards compatibility with CAPI
            if let idfa = advertiserData["idfa"] as? String {
                enrichedEventData["idfa"] = idfa
            }
        }

        let workspaceIdValue = config?.workspaceId ?? ""
        return EventPayload(
            workspaceId: workspaceIdValue.isEmpty ? "ios_sdk" : workspaceIdValue,
            visitorId: visitorId,
            anonymousId: anonymousId,  // Include persistent anonymous ID
            sessionId: sessionId,
            eventId: eventId,
            eventName: eventName,
            eventData: enrichedEventData,
            fingerprintData: fingerprintData,
            source: "mobile_app",
            timestamp: timestamp,
            userId: currentUserId,
            userProperties: userProperties.isEmpty ? nil : userProperties
        )
    }
    
    /// Load persisted user data
    private func loadPersistedUserData() async {
        if let userId = await DatalyrStorage.shared.getString(StorageKeys.userId) {
            currentUserId = userId
        }
        
        if let properties = await DatalyrStorage.shared.getData(StorageKeys.userProperties) {
            do {
                if let dict = try JSONSerialization.jsonObject(with: properties) as? UserProperties {
                    userProperties = dict
                }
            } catch {
                errorLog("Failed to load user properties", error: error)
            }
        }
    }
    
    /// Persist user data
    private func persistUserData() async {
        if let userId = currentUserId {
            await DatalyrStorage.shared.setString(StorageKeys.userId, value: userId)
        }
        
        if !userProperties.isEmpty {
            do {
                let data = try JSONSerialization.data(withJSONObject: userProperties)
                await DatalyrStorage.shared.setData(StorageKeys.userProperties, value: data)
            } catch {
                errorLog("Failed to persist user properties", error: error)
            }
        }
    }
    
    /// Check and track app install
    private func checkAndTrackInstall() async {
        let isFirstLaunch = await DatalyrStorage.shared.getString(StorageKeys.firstLaunchTime) == nil
        
        if isFirstLaunch {
            let installTime = DateFormatter.iso8601.string(from: Date())
            await DatalyrStorage.shared.setString(StorageKeys.firstLaunchTime, value: installTime)
            
            var installData: EventData = [
                "platform": "ios",
                "sdk_version": "1.2.0",
                "install_time": installTime
            ]
            
            // Add attribution data if available
            if let attribution = attributionManager?.trackInstall() {
                installData.merge(attribution.toDictionary()) { (_, new) in new }
            }
            
            await track("app_install", eventData: installData)
        }
    }
    
    /// Setup notification observers for app lifecycle
    private func setupNotificationObservers() {
        #if canImport(UIKit)
        // App will resign active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        // App did become active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // App will terminate
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }
    
    #if canImport(UIKit)
    @objc private func appWillResignActive() {
        // Start background task
        backgroundTaskId = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        
        // Flush events before going to background
        Task {
            await flush()
        }
    }
    
    @objc private func appDidBecomeActive() {
        // End background task
        endBackgroundTask()
        
        // Refresh session if needed
        Task {
            await refreshSessionIfNeeded()
        }
    }
    
    @objc private func appWillTerminate() {
        // Final flush before termination
        Task {
            await flush()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }
    #endif
    
    /// Refresh session if timeout exceeded
    private func refreshSessionIfNeeded() async {
        let sessionTimeout: TimeInterval = 30 * 60 // 30 minutes
        let now = Date().timeIntervalSince1970
        
        if let lastTimestamp = await DatalyrStorage.shared.getDouble(StorageKeys.sessionTimestamp) {
            if now - lastTimestamp > sessionTimeout {
                sessionId = await refreshSessionId()
                debugLog("Session refreshed due to timeout")
            }
        }
    }
    
    /// Merge deferred attribution data from platform SDKs into attribution manager
    private func mergeDeferredAttribution(_ data: DeferredDeepLinkResult) async {
        debugLog("Processing deferred deep link attribution", data: [
            "source": data.source ?? "unknown",
            "has_fbclid": data.fbclid != nil,
            "has_ttclid": data.ttclid != nil
        ])

        var attributionData = getAttributionData()

        if let fbclid = data.fbclid {
            attributionData.fbclid = fbclid
            debugLog("Captured fbclid from deferred deep link: \(fbclid)")
        }
        if let ttclid = data.ttclid {
            attributionData.ttclid = ttclid
            debugLog("Captured ttclid from deferred deep link: \(ttclid)")
        }
        if let utmSource = data.utmSource {
            attributionData.utmSource = utmSource
            attributionData.campaignSource = utmSource
        }
        if let utmMedium = data.utmMedium {
            attributionData.utmMedium = utmMedium
            attributionData.campaignMedium = utmMedium
        }
        if let utmCampaign = data.utmCampaign {
            attributionData.utmCampaign = utmCampaign
            attributionData.campaignName = utmCampaign
        }
        if let utmContent = data.utmContent {
            attributionData.utmContent = utmContent
            attributionData.campaignContent = utmContent
        }
        if let utmTerm = data.utmTerm {
            attributionData.utmTerm = utmTerm
            attributionData.campaignTerm = utmTerm
        }
        if let campaignId = data.campaignId {
            attributionData.campaignId = campaignId
        }
        if let adsetId = data.adsetId {
            attributionData.adsetId = adsetId
        }
        if let adId = data.adId {
            attributionData.adId = adId
        }
        if let deepLinkUrl = data.url {
            attributionData.deepLinkUrl = deepLinkUrl
        }

        await setAttributionData(attributionData)

        // Track deferred attribution event
        await track("$deferred_attribution", eventData: [
            "source": data.source ?? "unknown",
            "fbclid": data.fbclid ?? "",
            "ttclid": data.ttclid ?? "",
            "campaign_id": data.campaignId ?? "",
            "deep_link_url": data.url ?? ""
        ])
    }

    /// Cleanup resources
    private func cleanup() {
        NotificationCenter.default.removeObserver(self)
        eventQueue?.destroy()
        #if canImport(UIKit)
        endBackgroundTask()
        #endif
    }
}

// MARK: - Auto Events Tracking Delegate

extension DatalyrSDK: AutoEventsTrackingDelegate {
    func trackEvent(_ eventName: String, properties: EventData?) {
        Task {
            await track(eventName, eventData: properties)
        }
    }
    
    func trackScreenView(_ screenName: String, properties: EventData?) {
        Task {
            await screen(screenName, properties: properties)
        }
    }
}

// MARK: - Attribution Data Extension

extension AttributionData {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if let label = child.label, let value = child.value as? String, !value.isEmpty {
                dict[label] = value
            }
        }
        
        return dict
    }
}

// MARK: - SDK Errors

public enum DatalyrError: Error, LocalizedError {
    case notInitialized
    case invalidConfiguration(String)
    case trackingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "SDK not initialized"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .trackingFailed(let message):
            return "Tracking failed: \(message)"
        }
    }
} 