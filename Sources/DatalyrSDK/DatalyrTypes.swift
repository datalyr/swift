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
        endpoint: String = "https://api.datalyr.com",
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1.0,
        timeout: TimeInterval = 15.0,
        batchSize: Int = 10,
        flushInterval: TimeInterval = 10.0,
        maxQueueSize: Int = 100,
        respectDoNotTrack: Bool = true,
        enableAutoEvents: Bool = false,
        enableAttribution: Bool = false,
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
    public let trackScreenViews: Bool
    public let trackAppUpdates: Bool
    public let trackPerformance: Bool
    public let sessionTimeoutMs: TimeInterval
    
    public init(
        trackSessions: Bool = true,
        trackScreenViews: Bool = true,
        trackAppUpdates: Bool = true,
        trackPerformance: Bool = false,
        sessionTimeoutMs: TimeInterval = 30 * 60 * 1000 // 30 minutes
    ) {
        self.trackSessions = trackSessions
        self.trackScreenViews = trackScreenViews
        self.trackAppUpdates = trackAppUpdates
        self.trackPerformance = trackPerformance
        self.sessionTimeoutMs = sessionTimeoutMs
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
    public let sessionId: String
    public let eventId: String
    public let eventName: String
    public let eventData: [String: AnyCodable]?
    public let fingerprintData: FingerprintData?
    public let source: String
    public let timestamp: String
    public let userId: String?
    public let userProperties: [String: AnyCodable]?
    
    public init(
        workspaceId: String,
        visitorId: String,
        sessionId: String,
        eventId: String,
        eventName: String,
        eventData: EventData? = nil,
        fingerprintData: FingerprintData? = nil,
        source: String = "mobile_app",
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        userId: String? = nil,
        userProperties: UserProperties? = nil
    ) {
        self.workspaceId = workspaceId
        self.visitorId = visitorId
        self.sessionId = sessionId
        self.eventId = eventId
        self.eventName = eventName
        self.eventData = eventData?.mapValues { AnyCodable($0) }
        self.fingerprintData = fingerprintData
        self.source = source
        self.timestamp = timestamp
        self.userId = userId
        self.userProperties = userProperties?.mapValues { AnyCodable($0) }
    }
}

// MARK: - Device Fingerprinting

/// Device fingerprint data
public struct FingerprintData: Codable {
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
    public var twclid: String?
    public var liClickId: String?
    public var msclkid: String?
    
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
        case fbclid, ttclid, gclid, twclid
        case liClickId = "li_click_id"
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
    }
}

// MARK: - Queue Types

/// Queued event for offline storage
public struct QueuedEvent: Codable {
    public let payload: EventPayload
    public let timestamp: TimeInterval
    public var retryCount: Int
    
    public init(payload: EventPayload, timestamp: TimeInterval = Date().timeIntervalSince1970, retryCount: Int = 0) {
        self.payload = payload
        self.timestamp = timestamp
        self.retryCount = retryCount
    }
}

// MARK: - Session Data

/// Session tracking data
public struct SessionData: Codable {
    public let sessionId: String
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
    public let sessionId: String
    public let currentUserId: String?
    public let queueStats: QueueStats
    public let attribution: AttributionData
    
    public init(
        initialized: Bool,
        workspaceId: String,
        visitorId: String,
        sessionId: String,
        currentUserId: String? = nil,
        queueStats: QueueStats,
        attribution: AttributionData
    ) {
        self.initialized = initialized
        self.workspaceId = workspaceId
        self.visitorId = visitorId
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
            try container.encode(floatValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let arrayValue as [Any]:
            let codableArray = arrayValue.map { AnyCodable($0) }
            try container.encode(codableArray)
        case let dictValue as [String: Any]:
            let codableDict = dictValue.mapValues { AnyCodable($0) }
            try container.encode(codableDict)
        case is NSNull:
            try container.encodeNil()
        default:
            try container.encodeNil()
        }
    }
} 