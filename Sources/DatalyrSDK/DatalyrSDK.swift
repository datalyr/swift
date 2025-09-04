import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Main SDK Class

/// Main Datalyr SDK class providing analytics tracking functionality
public class DatalyrSDK {
    
    // MARK: - Singleton
    
    /// Shared singleton instance
    public static let shared = DatalyrSDK()
    
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
        
        // Mark as initialized
        self.initialized = true
        
        // Check for app install (after SDK is marked as initialized)
        await checkAndTrackInstall()
        
        debugLog("Datalyr SDK initialized successfully", data: [
            "workspaceId": config.workspaceId,
            "visitorId": visitorId,
            "anonymousId": anonymousId,
            "sessionId": sessionId
        ])
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
    
    /// Get current attribution data
    /// - Returns: Attribution data
    public func getAttributionData() -> AttributionData {
        return attributionManager?.getAttributionData() ?? AttributionData()
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
            workspaceId: config.workspaceId,
            apiKey: config.apiKey,
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
        
        // NEW: Automatic SKAdNetwork encoding
        guard let encoder = conversionEncoder else {
            if config?.debug == true {
                debugLog("SKAdNetwork encoder not initialized. Pass skadTemplate in initialize() or use initializeWithSKAdNetwork()")
            }
            return
        }
        
        let conversionValue = encoder.encode(event: event, properties: eventData)
        
        if conversionValue > 0 {
            #if os(iOS)
            if #available(iOS 14.0, *) {
                SKAdNetwork.updateConversionValue(conversionValue)
                
                if config?.debug == true {
                    debugLog("SKAdNetwork conversion value updated: \(conversionValue) for event: \(event)", data: eventData)
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
    }
    
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
        enrichedEventData["sdk_version"] = "1.0.1"
        
        return EventPayload(
            workspaceId: config?.workspaceId?.isEmpty == false ? config!.workspaceId : "ios_sdk",
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
                "sdk_version": "1.0.1",
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