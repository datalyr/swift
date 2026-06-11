import Foundation
import StoreKit
import CryptoKit
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
    /// Events that arrived before initialize() completed. Flushed once init finishes.
    private var preInitQueue: [(eventName: String, eventData: EventData?)] = []
    /// identify()/alias() calls that arrived before init (FSR-33). Replayed after init,
    /// before regular pre-init events, so the identity is set first.
    private var preInitIdentityQueue: [PreInitIdentityCall] = []
    /// Deep-link URLs that arrived before init (FSR-5). Replayed before checkAndTrackInstall()
    /// so the install event can carry the launch deep link's params.
    private var preInitDeepLinkQueue: [URL] = []
    private let preInitLock = NSLock()
    private static let preInitQueueMax = 50

    /// A pre-init identify/alias call, buffered until initialize() completes (FSR-33).
    enum PreInitIdentityCall {
        case identify(userId: String, properties: UserProperties?)
        case alias(newUserId: String, previousId: String?)
    }
    internal var config: DatalyrConfig?
    private var httpClient: DatalyrHTTPClient?
    private var eventQueue: DatalyrEventQueue?
    // internal (not private) so DatalyrSDK+Public.handleDeepLink can reach the real parser.
    var attributionManager: AttributionManager?
    private var autoEventsManager: AutoEventsManager?
    
    // Session and user data
    private var visitorId: String = ""
    private var anonymousId: String = ""  // Persistent anonymous identifier
    private var sessionId: String = ""
    private var currentUserId: String?
    private var userProperties: UserProperties = [:]
    
    // SKAdNetwork conversion value encoder
    private var conversionEncoder: ConversionValueEncoder?

    // Platform integrations (Apple Search Ads, IDFA/ATT)
    private var platformIntegrationManager: PlatformIntegrationManager?

    // Cached advertiser data (IDFA, ATT status) — refreshed on ATT change
    private var cachedAdvertiserData: [String: Any]?

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
            throw DatalyrError.invalidConfiguration("apiKey is required for Datalyr SDK v2.1.3")
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
        self.httpClient = DatalyrHTTPClient(endpoint: config.endpoint.isEmpty ? "https://ingest.datalyr.com/track" : config.endpoint, config: httpConfig)
        
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

        // Record initial attribution to journey — but ONLY when it is genuinely NEW (FSR-34).
        // AttributionManager persists attribution forever (no TTL), so recording it
        // unconditionally on every cold launch appended a duplicate touchpoint with the same
        // old campaign and rolled the 90-day last-touch expiry forward each launch, making a
        // 2-year-old install campaign perpetually look like a fresh last-touch. Gate on the
        // attribution's capture-time vs the last recorded touch's capturedAt, and carry the
        // REAL capture timestamp into the touch instead of 0.
        if let attribution = attributionManager?.getAttributionData() {
            let hasAttribution = attribution.utmSource != nil ||
                                attribution.fbclid != nil ||
                                attribution.gclid != nil ||
                                attribution.lyr != nil

            let capturedAt = attribution.attributionCapturedAt ?? 0
            let lastTouchCapturedAt = JourneyManager.shared.getLastTouch()?.capturedAt ?? 0
            // Fresh iff we have a capture-time and it is newer than the last recorded touch.
            // (capturedAt == 0 means legacy/unknown — treat as NOT new so we don't re-roll.)
            let isNewAttribution = capturedAt > 0 && capturedAt > lastTouchCapturedAt

            if hasAttribution && isNewAttribution {
                var touchAttribution = TouchAttribution(
                    timestamp: capturedAt,
                    expiresAt: 0,
                    capturedAt: capturedAt
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
        let autoConfig = config.autoEventConfig ?? AutoEventConfig()
        if config.enableAutoEvents {
            self.autoEventsManager = AutoEventsManager(
                trackingDelegate: self,
                config: autoConfig
            )
            await autoEventsManager?.initialize()
        }

        // Enable automatic UIViewController screen tracking if configured
        #if canImport(UIKit)
        if autoConfig.autoTrackScreenViews {
            DispatchQueue.main.async {
                DatalyrSDK.enableAutomaticScreenTracking()
            }
        }
        #endif
        
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

        // Initialize platform integrations (Apple Search Ads, IDFA/ATT)
        self.platformIntegrationManager = PlatformIntegrationManager()
        await platformIntegrationManager?.initialize(config: config)

        // Cache advertiser data (IDFA, ATT status) once at init — refreshed on ATT change
        cachedAdvertiserData = platformIntegrationManager?.getAdvertiserData()

        // Mark as initialized AND snapshot+clear the pre-init buffers in the SAME critical
        // section track()/identify()/alias() use (FSR-90). Otherwise a concurrent call that
        // read initialized==false could append AFTER the drain and be lost forever. Setting
        // the flag and clearing the queue atomically closes that window.
        let queued: [(eventName: String, eventData: EventData?)]
        let queuedIdentity: [PreInitIdentityCall]
        let queuedDeepLinks: [URL]
        (queued, queuedIdentity, queuedDeepLinks) = preInitLock.withLock {
            self.initialized = true
            let events = preInitQueue
            let identity = preInitIdentityQueue
            let urls = preInitDeepLinkQueue
            preInitQueue = []
            preInitIdentityQueue = []
            preInitDeepLinkQueue = []
            return (events, identity, urls)
        }

        // Replay pre-init deep links FIRST so app_install (below) can carry their params (FSR-5).
        if !queuedDeepLinks.isEmpty {
            debugLog("Replaying \(queuedDeepLinks.count) pre-init deep link(s)")
            for url in queuedDeepLinks {
                await attributionManager?.handleDeepLink(url)
            }
        }

        // Replay pre-init identify/alias (FSR-33) before regular events so identity is set.
        if !queuedIdentity.isEmpty {
            debugLog("Replaying \(queuedIdentity.count) pre-init identity call(s)")
            for call in queuedIdentity {
                switch call {
                case .identify(let userId, let properties):
                    await identify(userId, properties: properties)
                case .alias(let newUserId, let previousId):
                    await alias(newUserId, previousId: previousId)
                }
            }
        }

        if !queued.isEmpty {
            debugLog("Flushing \(queued.count) pre-init event(s)")
            for item in queued {
                await track(item.eventName, eventData: item.eventData)
            }
        }

        // Attempt deferred web-to-app attribution on first install (IP-based matching)
        if config.enableAttribution, attributionManager?.isInstall() == true {
            await fetchDeferredWebAttribution()
        }

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
            preInitLock.withLock {
                if preInitQueue.count < DatalyrSDK.preInitQueueMax {
                    debugLog("Queuing pre-init event: \(eventName)")
                    preInitQueue.append((eventName: eventName, eventData: eventData))
                } else {
                    errorLog("Pre-init event queue full, dropping event: \(eventName)")
                }
            }
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

        // FSR-36: last-activity is the session-timeout anchor. Bump the stored session
        // timestamp on every tracked event so refreshSessionIfNeeded measures time since the
        // last activity, not since session CREATION — otherwise a continuously-active user
        // gets their session rotated mid-engagement the moment they cross 30 min of age.
        await DatalyrStorage.shared.setDouble(StorageKeys.sessionTimestamp, value: Date().timeIntervalSince1970)

        let payload = await createEventPayload(eventName: eventName, eventData: eventData)
        await eventQueue?.enqueue(payload)
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

        // Update session counters FIRST so enrichment has correct pageview count
        autoEventsManager?.recordScreenView(screenName)

        // Enrich with session data (pageview count, previous screen) if available
        if let enrichment = autoEventsManager?.getScreenViewEnrichment() {
            for (key, value) in enrichment where screenData[key] == nil {
                screenData[key] = value
            }
        }

        await track("pageview", eventData: screenData)
    }
    
    /// Identify a user
    /// - Parameters:
    ///   - userId: User identifier
    ///   - properties: Optional user properties
    public func identify(_ userId: String, properties: UserProperties? = nil) async {
        // FSR-33: buffer pre-init identify (like track() does) instead of dropping it.
        // Apps commonly call identify(userId) at launch concurrently with initialize();
        // a hard return there lost the identity entirely (no $identify, no visitor_user_links,
        // no web-attribution lookup) and every following event went out anonymous.
        let shouldBuffer: Bool = preInitLock.withLock {
            if !initialized {
                if preInitIdentityQueue.count < DatalyrSDK.preInitQueueMax {
                    debugLog("Queuing pre-init identify: \(userId)")
                    preInitIdentityQueue.append(.identify(userId: userId, properties: properties))
                } else {
                    errorLog("Pre-init identity queue full, dropping identify: \(userId)")
                }
                return true
            }
            return false
        }
        if shouldBuffer { return }

        debugLog("Identifying user: \(userId)", data: properties)

        // Update current user
        currentUserId = userId

        if let properties = properties {
            userProperties.merge(properties) { (_, new) in new }
        }

        // Persist user data
        await persistUserData()

        // Extract identity fields for advanced matching
        let email = properties?["email"] as? String
        let phone = properties?["phone"] as? String
        let firstName = properties?["first_name"] as? String ?? properties?["firstName"] as? String
        let lastName = properties?["last_name"] as? String ?? properties?["lastName"] as? String

        // Track $identify event for identity resolution
        var identifyData: EventData = [
            "user_id": userId,
            "anonymous_id": anonymousId,
            "properties": properties ?? [:]
        ]
        // Include PII fields at root level for server-side identity resolution
        if let email = email { identifyData["email"] = email }
        if let phone = phone { identifyData["phone"] = phone }
        if let firstName = firstName { identifyData["first_name"] = firstName }
        if let lastName = lastName { identifyData["last_name"] = lastName }

        await track("$identify", eventData: identifyData)

        // Fetch and merge web attribution if email is provided
        let emailForAttribution = email ?? (userId.contains("@") ? userId : nil)
        if let emailForLookup = emailForAttribution {
            await fetchAndMergeWebAttribution(email: emailForLookup)
        }
    }

    /// Fetch web attribution data for user and merge into mobile session
    /// Called automatically during identify() if email is provided
    private func fetchAndMergeWebAttribution(email: String) async {
        // Web→app attribution is a one-time, install-time fact: a user either had a
        // web touch before installing or didn't, and that doesn't change. So resolve
        // it AT MOST ONCE per email per install. Without this, every identify(email)
        // — which apps call on each session/launch — fires a fresh /attribution/lookup
        // (measured: ~100k/day from a single app, 99.7% misses). Skip if already done.
        let emailHash = Self.sha256Hex(email)
        if await webAttributionAlreadyChecked(emailHash) {
            debugLog("Web attribution already checked this install for this email; skipping lookup")
            return
        }

        guard let apiKey = config?.apiKey else {
            debugLog("API key not available for web attribution fetch")
            return
        }

        // IOS-18: log the hash prefix, not the raw email (PII), even in debug.
        debugLog("Fetching web attribution for email hash: \(emailHash.prefix(8))…")

        guard let url = URL(string: "https://api.datalyr.com/attribution/lookup") else {
            errorLog("Invalid attribution API URL")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-Datalyr-API-Key")
            // FSR-92: bound the awaited lookup at 10s (matching the deferred path) instead of
            // inheriting URLSession.shared's 60s default — identify() awaits this inline, so a
            // degraded lookup could stall onboarding up to a minute.
            request.timeoutInterval = 10

            let body = ["email": email]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                errorLog("Invalid response from attribution API")
                return
            }

            if httpResponse.statusCode != 200 {
                debugLog("Failed to fetch web attribution: \(httpResponse.statusCode)")
                return  // transient/non-200 — do NOT mark checked, so it retries next identify
            }

            // Definitive 200 answer (found or not). Record it so repeated identify(email)
            // calls don't re-run this immutable, install-time lookup. Only after a 200 —
            // network/non-200 errors fall through and retry on the next identify.
            await markWebAttributionChecked(emailHash)

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
                "web_user_id": attribution["user_id"] ?? "",
                "match_method": "email"
            ]

            // Add click IDs
            if let fbclid = attribution["fbclid"] { mergedData["fbclid"] = fbclid }
            if let gclid = attribution["gclid"] { mergedData["gclid"] = gclid }
            if let ttclid = attribution["ttclid"] { mergedData["ttclid"] = ttclid }
            if let gbraid = attribution["gbraid"] { mergedData["gbraid"] = gbraid }
            if let wbraid = attribution["wbraid"] { mergedData["wbraid"] = wbraid }
            // Emit BOTH `_fbp`/`_fbc` (the Meta cookie names the attribution MV +
            // postback actually extract — JSONExtractString(event_data,'_fbp')) AND the
            // bare keys. Previously only `fbp`/`fbc` were sent, which no reader extracts,
            // so the recovered web touch contributed no fbp/fbc to Meta CAPI (lower EMQ).
            if let fbp = attribution["_fbp"] ?? attribution["fbp"] {
                mergedData["_fbp"] = fbp
                mergedData["fbp"] = fbp
            }
            if let fbc = attribution["_fbc"] ?? attribution["fbc"] {
                mergedData["_fbc"] = fbc
                mergedData["fbc"] = fbc
            }

            // Add UTM parameters
            if let utmSource = attribution["utm_source"] { mergedData["utm_source"] = utmSource }
            if let utmMedium = attribution["utm_medium"] { mergedData["utm_medium"] = utmMedium }
            if let utmCampaign = attribution["utm_campaign"] { mergedData["utm_campaign"] = utmCampaign }
            if let utmContent = attribution["utm_content"] { mergedData["utm_content"] = utmContent }
            if let utmTerm = attribution["utm_term"] { mergedData["utm_term"] = utmTerm }
            if let timestamp = attribution["timestamp"] { mergedData["web_timestamp"] = timestamp }

            // Canonical web→app bridge event — email and IP paths both fire
            // $web_attribution_matched, distinguished by match_method, so server
            // bridges (Meta CAPI recovery, lyr) and dashboards see one event name.
            // (Previously this path fired $web_attribution_merged, which no reader
            // consumed — email-only matches never bridged webhook conversions.)
            await track("$web_attribution_matched", eventData: mergedData)

            // Update attribution manager with web data
            await attributionManager?.mergeWebAttribution(attribution)

            debugLog("Successfully merged web attribution into mobile session")

        } catch {
            errorLog("Error fetching web attribution: \(error.localizedDescription)")
            // Non-blocking - continue even if attribution fetch fails
        }
    }

    // MARK: - Web attribution dedup (once per email per install)

    private static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.lowercased().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Storage key: emails (hashed, no raw PII) whose web→app attribution we've
    /// already definitively resolved/checked this install — so repeated
    /// identify(email) calls don't re-run the immutable, install-time lookup.
    private static let webAttributionCheckedKey = "datalyr_web_attribution_checked"

    private func webAttributionAlreadyChecked(_ emailHash: String) async -> Bool {
        guard let raw = await DatalyrStorage.shared.getString(Self.webAttributionCheckedKey) else { return false }
        return raw.split(separator: ",").contains(where: { $0 == emailHash })
    }

    private func markWebAttributionChecked(_ emailHash: String) async {
        let raw = await DatalyrStorage.shared.getString(Self.webAttributionCheckedKey) ?? ""
        var hashes = raw.split(separator: ",").map(String.init)
        guard !hashes.contains(emailHash) else { return }
        hashes.append(emailHash)
        if hashes.count > 20 { hashes = Array(hashes.suffix(20)) } // bound growth (rare account switches)
        await DatalyrStorage.shared.setString(Self.webAttributionCheckedKey, value: hashes.joined(separator: ","))
    }

    /// Fetch deferred web attribution on first app install via IP-based matching.
    /// Recovers attribution data (fbclid, utm_*, etc.) from a prelander web visit
    /// by matching the device's IP to a recent $app_download_click web event.
    /// Called automatically during initialize() when a fresh install is detected.
    private func fetchDeferredWebAttribution() async {
        guard let apiKey = config?.apiKey else {
            debugLog("API key not available for deferred attribution fetch")
            return
        }

        debugLog("Fetching deferred web attribution via IP matching...")

        guard let url = URL(string: "https://api.datalyr.com/attribution/deferred-lookup") else {
            errorLog("Invalid deferred attribution API URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Datalyr-API-Key")
        request.timeoutInterval = 10

        let body: [String: Any] = ["platform": "ios"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                debugLog("Deferred attribution lookup failed")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let found = json["found"] as? Bool, found,
                  let attribution = json["attribution"] as? [String: Any] else {
                debugLog("No deferred web attribution found for this IP")
                return
            }

            debugLog("Deferred web attribution found", data: [
                "visitor_id": attribution["visitor_id"] ?? "nil",
                "has_fbclid": attribution["fbclid"] != nil ? "YES" : "NO",
                "has_gclid": attribution["gclid"] != nil ? "YES" : "NO",
                "utm_source": attribution["utm_source"] ?? "nil"
            ])

            // Merge web attribution into current session
            await attributionManager?.mergeWebAttribution(attribution)

            // Track match event for analytics
            var matchData: EventData = [
                "match_method": "ip"
            ]
            if let webVisitorId = attribution["visitor_id"] { matchData["web_visitor_id"] = webVisitorId }
            if let webUserId = attribution["user_id"] { matchData["web_user_id"] = webUserId }
            if let fbclid = attribution["fbclid"] { matchData["fbclid"] = fbclid }
            if let gclid = attribution["gclid"] { matchData["gclid"] = gclid }
            if let ttclid = attribution["ttclid"] { matchData["ttclid"] = ttclid }
            if let gbraid = attribution["gbraid"] { matchData["gbraid"] = gbraid }
            if let wbraid = attribution["wbraid"] { matchData["wbraid"] = wbraid }
            // Emit both `_fbp`/`_fbc` (extracted by the attribution MV + postback) and the
            // bare keys — see the email-path note above.
            if let fbp = attribution["_fbp"] ?? attribution["fbp"] {
                matchData["_fbp"] = fbp
                matchData["fbp"] = fbp
            }
            if let fbc = attribution["_fbc"] ?? attribution["fbc"] {
                matchData["_fbc"] = fbc
                matchData["fbc"] = fbc
            }
            if let utmSource = attribution["utm_source"] { matchData["utm_source"] = utmSource }
            if let utmMedium = attribution["utm_medium"] { matchData["utm_medium"] = utmMedium }
            if let utmCampaign = attribution["utm_campaign"] { matchData["utm_campaign"] = utmCampaign }
            if let utmContent = attribution["utm_content"] { matchData["utm_content"] = utmContent }
            if let utmTerm = attribution["utm_term"] { matchData["utm_term"] = utmTerm }
            if let timestamp = attribution["timestamp"] { matchData["web_timestamp"] = timestamp }

            await track("$web_attribution_matched", eventData: matchData)

            debugLog("Successfully merged deferred web attribution")

        } catch {
            errorLog("Error fetching deferred web attribution: \(error.localizedDescription)")
            // Non-blocking - email-based fallback will catch this on identify()
        }
    }

    /// Create an alias for the current user
    /// - Parameters:
    ///   - newUserId: New user identifier
    ///   - previousId: Previous user identifier (optional)
    public func alias(_ newUserId: String, previousId: String? = nil) async {
        // FSR-33: buffer pre-init alias (like track()/identify()) instead of dropping it.
        let shouldBuffer: Bool = preInitLock.withLock {
            if !initialized {
                if preInitIdentityQueue.count < DatalyrSDK.preInitQueueMax {
                    debugLog("Queuing pre-init alias: \(newUserId)")
                    preInitIdentityQueue.append(.alias(newUserId: newUserId, previousId: previousId))
                } else {
                    errorLog("Pre-init identity queue full, dropping alias: \(newUserId)")
                }
                return true
            }
            return false
        }
        if shouldBuffer { return }

        // FSR-32: default previousId to the id the SERVER actually keys anonymous events on.
        // Anonymous iOS events are written with visitor_id/anonymous_id = anonymousId (ingest
        // index.js:2318-2320); the alias link builder keys the visitor_user_links row on
        // anonymous_id = previousId (user-properties-updater.js:434-440). visitorId never lands
        // in those columns, so the old `?? visitorId` default produced a link matching ZERO
        // pre-alias anonymous events. Use anonymousId so an alias-first integration resolves.
        let previousUserId = previousId ?? currentUserId ?? anonymousId
        
        debugLog("Creating alias: \(newUserId) for \(previousUserId)")
        
        // Track $alias for identity resolution. The ingest link builder
        // (buildIdentifyAliasLinks) matches ONLY the event name `$alias` and reads
        // camelCase `previousId`/`userId` from event_data — iOS was sending the name
        // `alias` (no `$`) with snake_case keys, so NO visitor_user_link was ever
        // written for an alias (alias-based identity merges were silently dropped).
        // Emit the canonical name + both casings + anonymous_id. (Matches Node/RN.)
        await track("$alias", eventData: [
            "userId": newUserId,
            "previousId": previousUserId,
            "user_id": newUserId,
            "previous_id": previousUserId,
            "anonymous_id": anonymousId
        ])
        
        // Update current user
        currentUserId = newUserId
        await persistUserData()
    }
    
    /// Route a deep link to the attribution parser, buffering it if init hasn't finished.
    /// FSR-5: on a cold start from an ad click — the highest-value deep link of the install
    /// lifecycle — onOpenURL / SceneDelegate commonly fires while initialize() is still
    /// awaiting storage/network, when attributionManager is nil. The old optional-chain
    /// no-op silently dropped that URL. Buffer it and replay before checkAndTrackInstall().
    internal func routeDeepLink(_ url: URL) async {
        let buffered: Bool = preInitLock.withLock {
            if !initialized || attributionManager == nil {
                if preInitDeepLinkQueue.count < DatalyrSDK.preInitQueueMax {
                    debugLog("Buffering pre-init deep link: \(url.absoluteString)")
                    preInitDeepLinkQueue.append(url)
                } else {
                    errorLog("Pre-init deep-link queue full, dropping: \(url.absoluteString)")
                }
                return true
            }
            return false
        }
        if buffered { return }

        await attributionManager?.handleDeepLink(url)
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
        autoEventsManager?.updateSessionId(sessionId)  // keep auto-events session in lockstep (IOS-14)

        // FSR-6: regenerate the anonymousId too. It — not visitorId — is the SERVER's visitor
        // key: ingest writes visitor_id = anonymousId||distinctId (index.js:2320) and $identify
        // links anonymous_id = anonymousId (index.js:2534). Leaving it intact across
        // logout→reset→login-as-B re-linked B's $identify to the SAME anon id already linked to
        // A, merging two users' identities/attribution server-side. Rotating visitorId alone was
        // cosmetic. (Mirrors Segment/Mixpanel reset + the Node SDK NODE-6 fix.)
        anonymousId = "anon_\(generateUUID())"

        // Clear stored user data
        await DatalyrStorage.shared.removeValue(StorageKeys.userId)
        await DatalyrStorage.shared.removeValue(StorageKeys.userProperties)
        await DatalyrStorage.shared.setString(StorageKeys.visitorId, value: visitorId)
        await DatalyrStorage.shared.setString(StorageKeys.anonymousId, value: anonymousId)

        // FSR-93: drop the web-attribution-checked marker set. It dedupes the once-per-email
        // lookup against attribution we're about to wipe; leaving it would permanently block
        // re-recovery if the same user re-identifies on this install (logout/login, QA flows).
        await DatalyrStorage.shared.removeValue(Self.webAttributionCheckedKey)

        // Clear attribution data
        await attributionManager?.clearAttributionData()

        // FSR-7: a new user identity should start a fresh SKAN conversion-value window,
        // so reset the persisted high-water (NOT the per-install registration flag).
        UnifiedAttributionTracker.shared.resetConversionState()

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

    /// Get deferred deep link attribution data
    /// - Returns: nil — deferred deep linking is now handled via prelanders
    public func getDeferredAttributionData() -> DeferredDeepLinkResult? {
        return nil
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

        // Refresh cached advertiser data after ATT status change
        cachedAdvertiserData = platformIntegrationManager?.getAdvertiserData()

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

    // MARK: - Third-Party Integration Methods

    /// Get attribution data formatted for Superwall's `setUserAttributes()`
    /// Returns a flat `[String: String]` dictionary with only non-empty values
    ///
    /// Usage:
    /// ```swift
    /// Superwall.shared.setUserAttributes(DatalyrSDK.shared.getSuperwallAttributes())
    /// ```
    public func getSuperwallAttributes() -> [String: String] {
        let attribution = attributionManager?.getAttributionData() ?? AttributionData()
        let advertiser = cachedAdvertiserData
        var attrs: [String: String] = [:]

        func set(_ key: String, _ value: Any?) {
            guard let v = value else { return }
            if v is NSNull { return }
            let str: String
            if let s = v as? String {
                str = s
            } else {
                str = "\(v)"
            }
            guard !str.isEmpty, str != "nil", str != "<null>" else { return }
            attrs[key] = str
        }

        set("datalyr_id", visitorId.isEmpty ? nil : visitorId)
        set("media_source", attribution.utmSource)
        set("campaign", attribution.utmCampaign)
        set("adgroup", attribution.adsetId ?? attribution.utmContent)
        set("ad", attribution.adId)
        set("keyword", attribution.keyword)
        set("network", attribution.network)
        set("utm_source", attribution.utmSource)
        set("utm_medium", attribution.utmMedium)
        set("utm_campaign", attribution.utmCampaign)
        set("utm_term", attribution.utmTerm)
        set("utm_content", attribution.utmContent)
        set("lyr", attribution.lyr)
        set("fbclid", attribution.fbclid)
        set("gclid", attribution.gclid)
        set("ttclid", attribution.ttclid)
        set("idfa", advertiser?["idfa"])
        if let attRaw = advertiser?["att_status"] {
            let attInt = (attRaw as? Int) ?? Int("\(attRaw)")
            if let attInt = attInt {
                let statusMap: [Int: String] = [0: "notDetermined", 1: "restricted", 2: "denied", 3: "authorized"]
                set("att_status", statusMap[attInt] ?? "\(attRaw)")
            }
        }

        return attrs
    }

    /// Get attribution data formatted for RevenueCat's `Purchases.shared.attribution.setAttributes()`
    /// Returns a flat `[String: String]` dictionary with `$`-prefixed reserved keys
    ///
    /// Usage:
    /// ```swift
    /// Purchases.shared.attribution.setAttributes(DatalyrSDK.shared.getRevenueCatAttributes())
    /// ```
    public func getRevenueCatAttributes() -> [String: String] {
        let attribution = attributionManager?.getAttributionData() ?? AttributionData()
        let advertiser = cachedAdvertiserData
        var attrs: [String: String] = [:]

        func set(_ key: String, _ value: Any?) {
            guard let v = value else { return }
            if v is NSNull { return }
            let str: String
            if let s = v as? String {
                str = s
            } else {
                str = "\(v)"
            }
            guard !str.isEmpty, str != "nil", str != "<null>" else { return }
            attrs[key] = str
        }

        // Reserved attributes ($ prefix)
        set("$datalyrId", visitorId.isEmpty ? nil : visitorId)
        set("$mediaSource", attribution.utmSource)
        set("$campaign", attribution.utmCampaign)
        set("$adGroup", attribution.adsetId)
        set("$ad", attribution.adId)
        set("$keyword", attribution.keyword)
        set("$idfa", advertiser?["idfa"])
        if let attStatus = advertiser?["att_status"] as? UInt {
            let statusMap: [UInt: String] = [0: "notDetermined", 1: "restricted", 2: "denied", 3: "authorized"]
            set("$attConsentStatus", statusMap[attStatus] ?? "\(attStatus)")
        }

        // Custom attributes
        set("utm_source", attribution.utmSource)
        set("utm_medium", attribution.utmMedium)
        set("utm_campaign", attribution.utmCampaign)
        set("utm_term", attribution.utmTerm)
        set("utm_content", attribution.utmContent)
        set("lyr", attribution.lyr)
        set("fbclid", attribution.fbclid)
        set("gclid", attribution.gclid)
        set("ttclid", attribution.ttclid)
        set("wbraid", attribution.wbraid)
        set("gbraid", attribution.gbraid)
        set("network", attribution.network)
        set("creative_id", attribution.creativeId)

        return attrs
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
            // FSR-7: route through the single guarded updater (UnifiedAttributionTracker)
            // instead of calling SKAdNetwork.updatePostbackConversionValue directly. That
            // updater persists a cross-launch high-water (fine + coarse + locked) and only
            // sends strict increases, so a later low-funnel event (view_item fine 8) can't
            // downgrade an earlier higher value (begin_checkout fine 32) — SKAN 4 permits
            // decreasing values but the SDK must not. (Encoder bit schema unchanged — IOS-24.)
            let applied = await UnifiedAttributionTracker.shared.updateConversionValue(
                fineValue: result.fineValue,
                coarseValue: result.coarseValue,
                lockWindow: result.lockWindow
            )
            if config?.debug == true {
                if applied {
                    debugLog("SKAdNetwork conversion value updated - fine: \(result.fineValue), coarse: \(result.coarseValue), lock: \(result.lockWindow) for event: \(event)", data: eventData)
                } else {
                    debugLog("SKAdNetwork conversion value not applied (not higher than persisted high-water, or window locked) for event: \(event)")
                }
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
    }

    /// Track complete registration event
    /// - Parameter method: Registration method (e.g., "email", "facebook", "google")
    public func trackCompleteRegistration(method: String? = nil) async {
        var properties: EventData = [:]
        if let method = method { properties["method"] = method }

        await trackWithSKAdNetwork("complete_registration", eventData: properties)
    }

    /// Track search event
    /// - Parameters:
    ///   - query: Search query string
    ///   - resultIds: Array of result product IDs (optional)
    public func trackSearch(query: String, resultIds: [String]? = nil) async {
        var properties: EventData = ["query": query]
        if let resultIds = resultIds { properties["result_ids"] = resultIds }

        await track("search", eventData: properties)
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
    }

    /// Track add payment info event
    /// - Parameter success: Whether payment info was added successfully
    public func trackAddPaymentInfo(success: Bool = true) async {
        await track("add_payment_info", eventData: ["success": success])
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
        let deviceContext = await createDeviceContext()

        var enrichedEventData = eventData ?? [:]

        // Add standard properties
        enrichedEventData["platform"] = "ios"
        enrichedEventData["anonymous_id"] = anonymousId  // Include for attribution
        enrichedEventData["sdk_version"] = "2.1.7"

        // App info from Bundle
        let bundle = Bundle.main
        enrichedEventData["app_name"] = bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String ?? ""
        enrichedEventData["app_version"] = getAppVersion()
        enrichedEventData["app_build"] = getAppBuildNumber()
        enrichedEventData["app_namespace"] = bundle.bundleIdentifier ?? ""

        // Device info
        #if canImport(UIKit)
        let device = UIDevice.current
        enrichedEventData["os_version"] = device.systemVersion
        enrichedEventData["device_model"] = getDeviceModelName()
        enrichedEventData["idfv"] = device.identifierForVendor?.uuidString

        let screen = UIScreen.main
        enrichedEventData["screen_width"] = Int(screen.bounds.width)
        enrichedEventData["screen_height"] = Int(screen.bounds.height)
        enrichedEventData["screen_density"] = screen.scale
        #else
        enrichedEventData["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        // Locale, timezone, carrier
        enrichedEventData["locale"] = Locale.current.identifier
        enrichedEventData["timezone"] = TimeZone.current.identifier
        enrichedEventData["carrier"] = getCarrierName()

        // ISO-3166-1 alpha-2 country derived from the device locale. For users
        // who skip a web prelander entirely (no web→app bridge to inherit geo
        // from), this is the only zero-config country signal — meta.js
        // USER_DATA_PATHS.country picks up top-level `country` as its first
        // match key and hashes for CAPI. Prefer Locale.region.identifier
        // (iOS 16+ canonical API); fall back to parsing Locale.current.identifier
        // ("en_US" → "US") for older OS versions.
        if let country = currentCountryCode() {
            enrichedEventData["country"] = country
        }

        // Apple Search Ads attribution if available
        if let asaData = platformIntegrationManager?.getAppleSearchAdsData() {
            enrichedEventData.merge(asaData) { (_, new) in new }
        }

        // Advertiser data (IDFA, ATT status) for server-side postback
        // Uses cached data — refreshed at init and on ATT change
        if let advertiserData = cachedAdvertiserData {
            enrichedEventData["advertiser_data"] = advertiserData
            // Include key fields at root level for postback workers
            if let idfa = advertiserData["idfa"] as? String {
                enrichedEventData["idfa"] = idfa
            }
            if let attStatus = advertiserData["att_status"] {
                enrichedEventData["att_status"] = attStatus
            }
            if let trackingAuthorized = advertiserData["tracking_authorized"] {
                enrichedEventData["advertiser_tracking_enabled"] = trackingAuthorized
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
            deviceContext: deviceContext,
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
            // FSR-1: JSONSerialization raises an uncatchable NSException for non-JSON
            // values (Date/URL/UUID), which identify(userId, properties: ["d": Date()])
            // routinely passes — that would crash the HOST APP. Sanitize to a JSON-safe
            // shape first (matching the wire representation), never call the raw dict.
            let jsonSafe = JSONSerialization.isValidJSONObject(userProperties)
                ? userProperties
                : sanitizeForJSONObject(userProperties)
            guard JSONSerialization.isValidJSONObject(jsonSafe) else {
                errorLog("User properties not JSON-serializable after sanitization; skipping persist")
                return
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: jsonSafe)
                await DatalyrStorage.shared.setData(StorageKeys.userProperties, value: data)
            } catch {
                errorLog("Failed to persist user properties", error: error)
            }
        }
    }
    
    /// Check and track app install
    private func checkAndTrackInstall() async {
        let isFirstLaunch = await DatalyrStorage.shared.getString("datalyr_app_install_tracked") == nil
        
        if isFirstLaunch {
            let installTime = DateFormatter.iso8601.string(from: Date())
            await DatalyrStorage.shared.setString("datalyr_app_install_tracked", value: installTime)
            
            var installData: EventData = [
                "platform": "ios",
                "sdk_version": "2.1.7",
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
        // FSR-91: capture THIS resign's task id locally and end exactly it — don't route
        // through the shared backgroundTaskId field. Otherwise a slow flush #1 (per-event
        // HTTP retries can take tens of seconds) could end task B begun by a later resign #2,
        // suspending the app mid-send. (Mirrors the appWillTerminate path's local-taskId pattern.)
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "datalyr.resign.flush")
        backgroundTaskId = taskId  // kept so didBecomeActive's endBackgroundTask() can release it on quick foreground

        Task {
            await flush()
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
                // If the field still points at this task, clear it so endBackgroundTask() is a no-op.
                if backgroundTaskId == taskId { backgroundTaskId = .invalid }
            }
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
        // Final flush before termination, inside a background-task scope so the flush gets
        // the OS time budget instead of being killed with the process mid-send. (Events are
        // already persisted on enqueue, so anything not delivered here survives to next launch.)
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "datalyr.terminate.flush")
        Task {
            await flush()
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
            }
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
                autoEventsManager?.updateSessionId(sessionId)  // keep auto-events session in lockstep (IOS-14)
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

    /// FSR-36: AutoEventsManager minted a new session id (post-timeout foreground). Adopt
    /// it as the SDK's own session id so event payloads + context.session_id stay in lockstep
    /// with session_start/session_end, instead of the event stream running under a stale id.
    func autoEventsDidRotateSession(to newSessionId: String) {
        guard sessionId != newSessionId else { return }
        sessionId = newSessionId
        debugLog("SDK session id adopted from auto-events rotation", data: ["sessionId": newSessionId])
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