import Foundation

// MARK: - Configuration

/// Configuration for the Datalyr SDK
public struct DatalyrConfig {
    public let apiKey: String // Required for server-side tracking
    public let workspaceId: String // Optional for backward compatibility
    public let useServerTracking: Bool // Flag to use new server API (default: true)
    public let debug: Bool
    public let endpoint: String
    public let maxRetries: Int
    public let retryDelay: TimeInterval
    public let timeout: TimeInterval
    public let batchSize: Int
    public let flushInterval: TimeInterval
    public let maxQueueSize: Int
    /// - Warning: **Not implemented.** This value is stored and never read — there
    ///   is no Do-Not-Track or consent gate anywhere in the iOS SDK, and setting it
    ///   to `true` does not stop or limit collection. The only way to stop
    ///   collection today is to not call `initialize()`.
    ///
    ///   It is kept (rather than removed) because removing a public property is a
    ///   source-breaking change. Honouring it properly means building a consent
    ///   apparatus the mobile SDKs do not have — the web SDK's `shouldTrack()` is
    ///   the reference implementation. Tracked as DEP-01.
    @available(*, deprecated, message: "Not implemented — stored but never read. Setting this does NOT limit collection.")
    public let respectDoNotTrack: Bool
    public let enableAutoEvents: Bool
    public let enableAttribution: Bool
    public let autoEventConfig: AutoEventConfig?
    public let skadTemplate: String?

    public init(
        apiKey: String,
        workspaceId: String = "",
        useServerTracking: Bool = true,
        debug: Bool = false,
        endpoint: String = "https://ingest.datalyr.com/track",
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1.0,
        timeout: TimeInterval = 15.0,
        batchSize: Int = 10,
        flushInterval: TimeInterval = 10.0,
        maxQueueSize: Int = 1000, // TR-05: was 100 (silently dropped an offline backlog >100)
        respectDoNotTrack: Bool = true,
        enableAutoEvents: Bool = true,
        enableAttribution: Bool = true,
        autoEventConfig: AutoEventConfig? = nil,
        skadTemplate: String? = nil
    ) {
        self.apiKey = apiKey
        self.workspaceId = workspaceId
        self.useServerTracking = useServerTracking
        self.debug = debug
        self.endpoint = endpoint
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.timeout = timeout
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.maxQueueSize = maxQueueSize
        self.respectDoNotTrack = respectDoNotTrack
        self.enableAutoEvents = enableAutoEvents
        self.enableAttribution = enableAttribution
        self.autoEventConfig = autoEventConfig
        self.skadTemplate = skadTemplate
    }
}

// MARK: - Auto Events Configuration

/// Configuration for automatic event tracking
public struct AutoEventConfig {
    public let trackSessions: Bool
    /// Enable screen view event tracking via `screen()` calls (manual or automatic).
    /// When false, all screen events are suppressed. Default: true
    public let trackScreenViews: Bool
    /// - Warning: **Not implemented.** Never read. `app_update` is manual-only —
    ///   call `trackAppUpdate(previousVersion:currentVersion:)` yourself. (DEP-01)
    @available(*, deprecated, message: "Not implemented — app_update is manual-only via trackAppUpdate().")
    public let trackAppUpdates: Bool
    /// - Warning: **Not implemented.** Never read. The iOS SDK emits no
    ///   performance events at all. (DEP-01)
    @available(*, deprecated, message: "Not implemented — the SDK emits no performance events.")
    public let trackPerformance: Bool
    public let sessionTimeoutMs: TimeInterval
    /// Automatically swizzle UIViewController.viewDidAppear to detect screen changes.
    /// When enabled, the SDK calls `enableAutomaticScreenTracking()` during initialization.
    /// System view controllers (UINavigationController, UITabBarController, etc.) are
    /// filtered out automatically.
    ///
    /// **For SwiftUI apps:** UIHostingController is filtered — use the `.datalyrScreen()`
    /// view modifier instead for SwiftUI views.
    ///
    /// Default: false (opt-in)
    public let autoTrackScreenViews: Bool

    public init(
        trackSessions: Bool = true,
        trackScreenViews: Bool = true,
        trackAppUpdates: Bool = true,
        trackPerformance: Bool = false,
        sessionTimeoutMs: TimeInterval = 30 * 60 * 1000, // 30 minutes
        autoTrackScreenViews: Bool = false
    ) {
        self.trackSessions = trackSessions
        self.trackScreenViews = trackScreenViews
        self.trackAppUpdates = trackAppUpdates
        self.trackPerformance = trackPerformance
        self.sessionTimeoutMs = sessionTimeoutMs
        self.autoTrackScreenViews = autoTrackScreenViews
    }
}

// MARK: - Event Data Types

/// Event data dictionary type
public typealias EventData = [String: Any]

/// User properties dictionary type  
public typealias UserProperties = [String: Any]

// MARK: - Event Payload

/// Complete event payload sent to the API
public struct EventPayload: Codable {
    public let workspaceId: String
    public let visitorId: String
    public let anonymousId: String  // Persistent anonymous identifier
    public let sessionId: String
    public let eventId: String
    public let eventName: String
    public let eventData: [String: AnyCodable]?
    public let deviceContext: DeviceContext?
    public let source: String
    public let timestamp: String
    public let userId: String?
    public let userProperties: [String: AnyCodable]?

    /// `deviceContext` is stored on disk (the persisted event queue) under its original
    /// key `fingerprintData`, so queues written by any earlier release still decode and a
    /// downgrade can still read a queue written by this one. On the network (the legacy
    /// `useServerTracking: false` path, which posts this Codable payload as-is to a custom
    /// endpoint) it is sent under both `device_context` and `fingerprintData`. Decoding
    /// accepts both.
    private enum CodingKeys: String, CodingKey {
        case workspaceId, visitorId, anonymousId, sessionId
        case eventId, eventName, eventData
        case deviceContext = "fingerprintData"
        case wireDeviceContext = "device_context"
        case source, timestamp, userId, userProperties
    }

    /// Set to true in an encoder's userInfo to produce the network shape (`device_context`
    /// added next to `fingerprintData`) instead of the on-disk shape.
    internal static let wireFormatKey = CodingUserInfoKey(rawValue: "com.datalyr.eventPayload.wireFormat")!

    /// Encoder for posting an EventPayload directly (legacy path).
    internal static func wireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[wireFormatKey] = true
        return encoder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        visitorId = try c.decode(String.self, forKey: .visitorId)
        anonymousId = try c.decode(String.self, forKey: .anonymousId)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        eventId = try c.decode(String.self, forKey: .eventId)
        eventName = try c.decode(String.self, forKey: .eventName)
        eventData = try c.decodeIfPresent([String: AnyCodable].self, forKey: .eventData)
        deviceContext = try c.decodeIfPresent(DeviceContext.self, forKey: .deviceContext)
            ?? c.decodeIfPresent(DeviceContext.self, forKey: .wireDeviceContext)
        source = try c.decode(String.self, forKey: .source)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        userProperties = try c.decodeIfPresent([String: AnyCodable].self, forKey: .userProperties)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(visitorId, forKey: .visitorId)
        try c.encode(anonymousId, forKey: .anonymousId)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(eventId, forKey: .eventId)
        try c.encode(eventName, forKey: .eventName)
        try c.encodeIfPresent(eventData, forKey: .eventData)
        // Disk: `fingerprintData` only. Wire: both keys — this path posts to a caller-chosen
        // endpoint that may still read `fingerprintData`.
        try c.encodeIfPresent(deviceContext, forKey: .deviceContext)
        if (encoder.userInfo[Self.wireFormatKey] as? Bool) == true {
            try c.encodeIfPresent(deviceContext, forKey: .wireDeviceContext)
        }
        try c.encode(source, forKey: .source)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encodeIfPresent(userProperties, forKey: .userProperties)
    }
    
    public init(
        workspaceId: String,
        visitorId: String,
        anonymousId: String,
        sessionId: String,
        eventId: String,
        eventName: String,
        eventData: EventData? = nil,
        deviceContext: DeviceContext? = nil,
        source: String = "mobile_app",
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        userId: String? = nil,
        userProperties: UserProperties? = nil
    ) {
        self.workspaceId = workspaceId
        self.visitorId = visitorId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.eventId = eventId
        self.eventName = eventName
        self.eventData = eventData?.mapValues { AnyCodable($0) }
        self.deviceContext = deviceContext
        self.source = source
        self.timestamp = timestamp
        self.userId = userId
        self.userProperties = userProperties?.mapValues { AnyCodable($0) }
    }
}

// MARK: - Device Context

/// Device context data
public struct DeviceContext: Codable {
    public let deviceId: String?
    public let deviceInfo: DeviceInfo?
    
    public init(deviceId: String? = nil, deviceInfo: DeviceInfo? = nil) {
        self.deviceId = deviceId
        self.deviceInfo = deviceInfo
    }
}

/// Detailed device information
public struct DeviceInfo: Codable {
    public let model: String
    public let manufacturer: String
    public let osVersion: String
    public let screenSize: String
    public let timezone: String
    public let locale: String?
    public let carrier: String?
    public let isEmulator: Bool
    
    public init(
        model: String,
        manufacturer: String,
        osVersion: String,
        screenSize: String,
        timezone: String,
        locale: String? = nil,
        carrier: String? = nil,
        isEmulator: Bool = false
    ) {
        self.model = model
        self.manufacturer = manufacturer
        self.osVersion = osVersion
        self.screenSize = screenSize
        self.timezone = timezone
        self.locale = locale
        self.carrier = carrier
        self.isEmulator = isEmulator
    }
}

// MARK: - Attribution Data

/// Attribution tracking data
public struct AttributionData: Codable {
    // Install Attribution
    public var installTime: String?
    public var firstOpenTime: String?
    
    // Datalyr LYR System (CRITICAL!)
    public var lyr: String?
    public var datalyr: String?
    public var dlTag: String?
    public var dlCampaign: String?
    
    // Campaign Attribution (UTM)
    public var utmSource: String?
    public var utmMedium: String?
    public var utmCampaign: String?
    public var utmTerm: String?
    public var utmContent: String?
    public var utmId: String?
    public var utmSourcePlatform: String?
    public var utmCreativeFormat: String?
    public var utmMarketingTactic: String?
    
    // Platform Click IDs
    public var fbclid: String?
    public var ttclid: String?
    public var gclid: String?
    public var wbraid: String?
    public var gbraid: String?
    public var dclid: String?   // Google Display & Video 360 (ingest clickIdMapping supports it)
    public var oppref: String?
    public var twclid: String?
    /// LinkedIn's click id (`li_fat_id`, the param LinkedIn actually appends).
    public var liFatId: String?
    /// Snapchat click id. Captured from `ScCid` / `sccid` / `sclid`; `sclid` is the canonical name.
    public var sclid: String?
    /// AppLovin click id (`aleid`). Opaque, stored verbatim.
    public var aleid: String?
    /// AppLovin app-user id (`alart`). Opaque, stored verbatim. Not a click id. Sent only on
    /// `app_install` / `$deep_link` (see `appUserIdEvents`) and only with ATT authorized.
    public var alart: String?
    public var msclkid: String?

    /// Renamed: LinkedIn never sends `li_click_id`. Reads and writes `liFatId`.
    @available(*, deprecated, renamed: "liFatId")
    public var liClickId: String? {
        get { liFatId }
        set { liFatId = newValue }
    }

    /// A `li_click_id` persisted by 2.1.16 and earlier. Decoded only so it can be moved to
    /// `liFatId` by `migrateLegacyClickIds()`; nil after migration, so it is never re-encoded
    /// (synthesized Codable skips nil optionals) and never reaches the wire.
    internal var legacyLiClickId: String?
    
    // Partner & Affiliate Tracking
    public var partnerId: String?
    public var affiliateId: String?
    public var referrerId: String?
    public var sourceId: String?
    
    // Campaign Details
    public var campaignId: String?
    public var adId: String?
    public var adsetId: String?
    public var creativeId: String?
    public var placementId: String?
    /// Meta's `{{placement}}` macro — a placement NAME (Feed, Reels, Story), not an id.
    /// Distinct from `placementId` above, which is the numeric form other platforms send.
    public var placement: String?
    /// Meta's `{{site_source_name}}` macro — which surface ran the ad (`ig`, `fb`, `msg`).
    public var siteSourceName: String?
    public var keyword: String?
    public var matchtype: String?
    public var network: String?
    public var device: String?
    
    // Standard Attribution Fields
    public var campaignSource: String?
    public var campaignMedium: String?
    public var campaignName: String?
    public var campaignTerm: String?
    public var campaignContent: String?
    
    // Additional attribution data
    public var referrer: String?
    public var deepLinkUrl: String?
    public var installReferrer: String?
    public var attributionTimestamp: String?
    /// Epoch milliseconds when this attribution was captured/merged (FSR-34). Lets the
    /// init-time journey recorder tell a FRESH touch from a relaunch over stale persisted
    /// attribution, so it doesn't re-append duplicate touchpoints and roll the 90-day expiry
    /// forward on every cold launch.
    public var attributionCapturedAt: TimeInterval?

    public init() {}
    
    // Coding keys for JSON serialization
    private enum CodingKeys: String, CodingKey {
        case installTime = "install_time"
        case firstOpenTime = "first_open_time"
        case lyr, datalyr
        case dlTag = "dl_tag"
        case dlCampaign = "dl_campaign"
        case utmSource = "utm_source"
        case utmMedium = "utm_medium"
        case utmCampaign = "utm_campaign"
        case utmTerm = "utm_term"
        case utmContent = "utm_content"
        case utmId = "utm_id"
        case utmSourcePlatform = "utm_source_platform"
        case utmCreativeFormat = "utm_creative_format"
        case utmMarketingTactic = "utm_marketing_tactic"
        // FSR-35: `oppref` (OpenAI click-id) was declared on the struct but MISSING here, so
        // the synthesized encode/decode silently skipped it — captured then lost on relaunch.
        case fbclid, ttclid, gclid, wbraid, gbraid, dclid, oppref, twclid
        case liFatId = "li_fat_id"
        case sclid, aleid, alart
        case legacyLiClickId = "li_click_id"
        case msclkid
        case partnerId = "partner_id"
        case affiliateId = "affiliate_id"
        case referrerId = "referrer_id"
        case sourceId = "source_id"
        case campaignId = "campaign_id"
        case adId = "ad_id"
        case adsetId = "adset_id"
        case creativeId = "creative_id"
        case placementId = "placement_id"
        case placement
        case siteSourceName = "site_source_name"
        case keyword, matchtype, network, device
        case campaignSource = "campaign_source"
        case campaignMedium = "campaign_medium"
        case campaignName = "campaign_name"
        case campaignTerm = "campaign_term"
        case campaignContent = "campaign_content"
        case referrer
        case deepLinkUrl = "deep_link_url"
        case installReferrer = "install_referrer"
        case attributionTimestamp = "attribution_timestamp"
        case attributionCapturedAt = "attribution_captured_at"
    }

    /// Click ids in primary order, as (wire name, value). The first present one is a touch's
    /// `clickIdType`. fbclid > gclid > ttclid is the order the SDK always used; the rest follow
    /// the web SDK's CLICK_IDS order, with AppLovin last. `alart` is an app-user id, not a click.
    internal var clickIdsInPrimaryOrder: [(type: String, value: String?)] {
        return [
            ("fbclid", fbclid), ("gclid", gclid), ("ttclid", ttclid),
            ("gbraid", gbraid), ("wbraid", wbraid), ("oppref", oppref), ("msclkid", msclkid),
            ("twclid", twclid), ("li_fat_id", liFatId), ("sclid", sclid), ("dclid", dclid),
            ("aleid", aleid)
        ]
    }

    /// Wire name of the primary click id, or nil when none is present. Presence is `!= nil`,
    /// exactly as the original fbclid/gclid/ttclid chain tested it.
    internal var primaryClickIdType: String? {
        return clickIdsInPrimaryOrder.first(where: { $0.value != nil })?.type
    }

    /// App-user ids (not click ids). AppLovin's `alart` is a persistent per-user id: captured
    /// and persisted, but sent only on `appUserIdEvents`, never on every event (it would ride
    /// every event regardless of ATT / opt-out, to the non-tracking host when there is no IDFA).
    internal static let appUserIdKeys: Set<String> = ["alart"]

    /// Events that carry the persisted app-user ids. `$web_attribution_matched` is not here: it
    /// carries `alart` only when the lookup response returned one (`webMatchEventIds`).
    internal static let appUserIdEvents: Set<String> = ["app_install", "$deep_link"]

    /// True only for ATT `.authorized` (raw value 3). notDetermined (0), restricted (1), denied
    /// (2) and an unknown status all count as not authorized. `attStatus` is the cached
    /// `att_status` from `getAdvertiserData()` (UInt), so it matches the IDFA gate exactly.
    internal static func isTrackingAuthorized(attStatus: Any?) -> Bool {
        if let v = attStatus as? UInt { return v == 3 }
        if let v = attStatus as? Int { return v == 3 }
        return false
    }

    /// Remove the app-user ids from an outgoing event's properties unless ATT is authorized.
    internal static func removeAppUserIds(from eventData: inout [String: Any], unlessAttStatus attStatus: Any?) {
        guard !isTrackingAuthorized(attStatus: attStatus) else { return }
        for key in appUserIdKeys { eventData.removeValue(forKey: key) }
    }

    /// Whether this attribution should record a journey touch at startup: a UTM source, any
    /// click id (was fbclid/gclid only, so a bare `?li_fat_id=` / `?ttclid=` / `?aleid=` link
    /// recorded nothing), or a `lyr` tag. `alart` alone does not count: it is not a click.
    internal var hasJourneyAttribution: Bool {
        return utmSource != nil || primaryClickIdType != nil || lyr != nil
    }

    /// The touch recorded for this attribution, stamped with its real capture time.
    internal func makeTouchAttribution(capturedAt: TimeInterval) -> TouchAttribution {
        var touch = TouchAttribution(timestamp: capturedAt, expiresAt: 0, capturedAt: capturedAt)
        touch.source = utmSource ?? campaignSource
        touch.medium = utmMedium ?? campaignMedium
        touch.campaign = utmCampaign ?? campaignName
        touch.fbclid = fbclid
        touch.gclid = gclid
        touch.ttclid = ttclid
        touch.gbraid = gbraid
        touch.wbraid = wbraid
        touch.oppref = oppref
        touch.twclid = twclid
        touch.liFatId = liFatId
        touch.sclid = sclid
        touch.aleid = aleid
        touch.lyr = lyr
        // Every click id gets a type (was fbclid/gclid/ttclid only); those three keep their
        // precedence. Order lives in clickIdsInPrimaryOrder.
        touch.clickIdType = primaryClickIdType
        return touch
    }

    /// Move a legacy `li_click_id` to `liFatId` (an existing `liFatId` wins). Returns true
    /// when something changed, so the caller can re-persist.
    @discardableResult
    internal mutating func migrateLegacyClickIds() -> Bool {
        guard let legacy = legacyLiClickId else { return false }
        if (liFatId ?? "").isEmpty, !legacy.isEmpty {
            liFatId = legacy
        }
        legacyLiClickId = nil
        return true
    }
}

// MARK: - Queue Types

/// Queued event for offline storage
public struct QueuedEvent: Codable {
    public let payload: EventPayload
    public let timestamp: TimeInterval
    public var retryCount: Int
    /// Number of times this event has been replayed out of the dead-letter store. Bounds the
    /// replay loop so a permanently-rejected payload (400/413) is dropped after a few launches
    /// instead of cycling forever. Decodes as 0 for entries persisted before the field existed.
    public var replayCount: Int

    public init(payload: EventPayload, timestamp: TimeInterval = Date().timeIntervalSince1970, retryCount: Int = 0, replayCount: Int = 0) {
        self.payload = payload
        self.timestamp = timestamp
        self.retryCount = retryCount
        self.replayCount = replayCount
    }

    private enum CodingKeys: String, CodingKey {
        case payload, timestamp, retryCount, replayCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        payload = try c.decode(EventPayload.self, forKey: .payload)
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        replayCount = try c.decodeIfPresent(Int.self, forKey: .replayCount) ?? 0
    }
}

// MARK: - Session Data

/// Session tracking data
public struct SessionData: Codable {
    public var sessionId: String   // var: synced to the SDK session id on reset/timeout (IOS-14)
    public let startTime: Date
    public var lastActivityTime: Date
    public var eventCount: Int
    public var pageviewCount: Int
    public let appVersion: String
    public let osVersion: String
    
    public init(sessionId: String, startTime: Date = Date(), appVersion: String, osVersion: String) {
        self.sessionId = sessionId
        self.startTime = startTime
        self.lastActivityTime = startTime
        self.eventCount = 0
        self.pageviewCount = 0
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

// MARK: - HTTP Response

/// HTTP response wrapper
public struct HTTPResponse {
    public let success: Bool
    public let statusCode: Int
    public let data: Data?
    public let error: Error?
    
    public init(success: Bool, statusCode: Int, data: Data? = nil, error: Error? = nil) {
        self.success = success
        self.statusCode = statusCode
        self.data = data
        self.error = error
    }
}

// MARK: - SDK Status

/// SDK status information
public struct SDKStatus {
    public let initialized: Bool
    public let workspaceId: String
    public let visitorId: String
    public let anonymousId: String  // Persistent anonymous identifier
    public let sessionId: String
    public let currentUserId: String?
    public let queueStats: QueueStats
    public let attribution: AttributionData
    
    public init(
        initialized: Bool,
        workspaceId: String,
        visitorId: String,
        anonymousId: String,
        sessionId: String,
        currentUserId: String? = nil,
        queueStats: QueueStats,
        attribution: AttributionData
    ) {
        self.initialized = initialized
        self.workspaceId = workspaceId
        self.visitorId = visitorId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.currentUserId = currentUserId
        self.queueStats = queueStats
        self.attribution = attribution
    }
}

/// Event queue statistics
public struct QueueStats {
    public let queueSize: Int
    public let isProcessing: Bool
    public let isOnline: Bool
    public let oldestEventAge: TimeInterval?
    
    public init(queueSize: Int, isProcessing: Bool, isOnline: Bool, oldestEventAge: TimeInterval? = nil) {
        self.queueSize = queueSize
        self.isProcessing = isProcessing
        self.isOnline = isOnline
        self.oldestEventAge = oldestEventAge
    }
}

// MARK: - Codable Support for Any

/// Wrapper for Any values to be Codable
public struct AnyCodable: Codable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let floatValue as Float:
            try container.encode(Double(floatValue))
        case let stringValue as String:
            try container.encode(stringValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let dateValue as Date:
            try container.encode(ISO8601DateFormatter().string(from: dateValue))
        case let urlValue as URL:
            try container.encode(urlValue.absoluteString)
        case let numberValue as NSNumber:
            // NSNumber can wrap bool, int, or double
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                try container.encode(numberValue.boolValue)
            } else if numberValue.doubleValue == Double(numberValue.intValue) {
                try container.encode(numberValue.intValue)
            } else {
                try container.encode(numberValue.doubleValue)
            }
        case let arrayValue as [Any]:
            let codableArray = arrayValue.map { AnyCodable($0) }
            try container.encode(codableArray)
        case let dictValue as [String: Any]:
            let codableDict = dictValue.mapValues { AnyCodable($0) }
            try container.encode(codableDict)
        case is NSNull:
            try container.encodeNil()
        case let optional as Any? where optional == nil:
            try container.encodeNil()
        default:
            // Convert unknown types to string rather than dropping
            try container.encode("\(value)")
        }
    }
}

// MARK: - Deferred Deep Link Result

/// Result from platform SDK deferred deep link fetch
public struct DeferredDeepLinkResult {
    public var url: String?
    public var source: String?
    public var fbclid: String?
    public var ttclid: String?
    public var utmSource: String?
    public var utmMedium: String?
    public var utmCampaign: String?
    public var utmContent: String?
    public var utmTerm: String?
    public var campaignId: String?
    public var adsetId: String?
    public var adId: String?

    public init(
        url: String? = nil,
        source: String? = nil,
        fbclid: String? = nil,
        ttclid: String? = nil,
        utmSource: String? = nil,
        utmMedium: String? = nil,
        utmCampaign: String? = nil,
        utmContent: String? = nil,
        utmTerm: String? = nil,
        campaignId: String? = nil,
        adsetId: String? = nil,
        adId: String? = nil
    ) {
        self.url = url
        self.source = source
        self.fbclid = fbclid
        self.ttclid = ttclid
        self.utmSource = utmSource
        self.utmMedium = utmMedium
        self.utmCampaign = utmCampaign
        self.utmContent = utmContent
        self.utmTerm = utmTerm
        self.campaignId = campaignId
        self.adsetId = adsetId
        self.adId = adId
    }
}

// MARK: - SDK Delegate Protocol

/// Platform integration error types
public enum DatalyrPlatformError: Error, CustomStringConvertible {
    case skadnetworkUpdateFailed(underlyingError: Error?)
    case attributionFetchFailed(platform: String, underlyingError: Error?)
    case networkError(underlyingError: Error)
    case configurationError(message: String)

    public var description: String {
        switch self {
        case .skadnetworkUpdateFailed(let error):
            return "SKAdNetwork update failed: \(error?.localizedDescription ?? "Unknown error")"
        case .attributionFetchFailed(let platform, let error):
            return "Attribution fetch from \(platform) failed: \(error?.localizedDescription ?? "Unknown error")"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        }
    }

    public var platform: String {
        switch self {
        case .skadnetworkUpdateFailed: return "SKAdNetwork"
        case .attributionFetchFailed(let platform, _): return platform
        case .networkError: return "Network"
        case .configurationError: return "Configuration"
        }
    }
}

/// Delegate protocol for receiving SDK callbacks
/// Implement this protocol to receive notifications about SDK events and errors
public protocol DatalyrSDKDelegate: AnyObject {
    /// Called when a platform integration fails to send an event
    /// - Parameters:
    ///   - error: The platform error that occurred
    ///   - eventName: The name of the event that failed (if applicable)
    func datalyrDidFailToSendEvent(_ error: DatalyrPlatformError, eventName: String?)

    /// Called when attribution data is successfully retrieved
    /// - Parameter attribution: The attribution data
    func datalyrDidReceiveAttribution(_ attribution: AttributionData)

    /// Called when SKAdNetwork/AdAttributionKit conversion value is updated
    /// - Parameters:
    ///   - fineValue: The fine-grained value (0-63)
    ///   - coarseValue: The coarse value (low/medium/high) for SKAN 4.0+
    func datalyrDidUpdateConversionValue(fineValue: Int, coarseValue: String?)

    /// Called when the SDK is fully initialized
    func datalyrDidInitialize()
}

/// Default implementations for optional delegate methods
public extension DatalyrSDKDelegate {
    func datalyrDidFailToSendEvent(_ error: DatalyrPlatformError, eventName: String?) {}
    func datalyrDidReceiveAttribution(_ attribution: AttributionData) {}
    func datalyrDidUpdateConversionValue(fineValue: Int, coarseValue: String?) {}
    func datalyrDidInitialize() {}
} 