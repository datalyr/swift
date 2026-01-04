import Foundation

// MARK: - Journey Types

/// Attribution data for a touch (first-touch or last-touch)
public struct TouchAttribution: Codable {
    public var timestamp: TimeInterval
    public var expiresAt: TimeInterval
    public var capturedAt: TimeInterval

    // Source attribution
    public var source: String?
    public var medium: String?
    public var campaign: String?
    public var term: String?
    public var content: String?

    // Click IDs
    public var clickId: String?
    public var clickIdType: String?
    public var fbclid: String?
    public var gclid: String?
    public var ttclid: String?
    public var gbraid: String?
    public var wbraid: String?

    // LYR tag
    public var lyr: String?

    // Context
    public var landingPage: String?
    public var referrer: String?
}

/// A single touchpoint in the customer journey
public struct TouchPoint: Codable {
    public let timestamp: TimeInterval
    public let sessionId: String
    public var source: String?
    public var medium: String?
    public var campaign: String?
    public var clickIdType: String?
}

/// Journey tracking summary for debugging
public struct JourneySummary {
    public let hasFirstTouch: Bool
    public let hasLastTouch: Bool
    public let touchpointCount: Int
    public let daysSinceFirstTouch: Int
    public let sources: [String]
}

// MARK: - Journey Manager

/// Journey manager for tracking customer touchpoints
/// Mirrors the Web SDK's journey tracking capabilities:
/// - First-touch attribution with 90-day expiration
/// - Last-touch attribution with 90-day expiration
/// - Up to 30 touchpoints stored
public class JourneyManager {
    public static let shared = JourneyManager()

    private let storage = DatalyrStorage.shared

    // Storage keys
    private let firstTouchKey = "first_touch"
    private let lastTouchKey = "last_touch"
    private let journeyKey = "journey"

    // 90-day attribution window (matching web SDK)
    private let attributionWindowMs: TimeInterval = 90 * 24 * 60 * 60 * 1000

    // Maximum touchpoints to store
    private let maxTouchpoints = 30

    // Cached data
    private var firstTouch: TouchAttribution?
    private var lastTouch: TouchAttribution?
    private var journey: [TouchPoint] = []
    private var initialized = false

    private init() {}

    // MARK: - Initialization

    /// Initialize journey tracking by loading persisted data
    public func initialize() async {
        guard !initialized else { return }

        debugLog("Initializing journey manager...")

        // Load first touch
        if let savedFirstTouch: TouchAttribution = await storage.getCodable(firstTouchKey, type: TouchAttribution.self) {
            if !isExpired(savedFirstTouch) {
                firstTouch = savedFirstTouch
            } else {
                await storage.removeValue(firstTouchKey)
            }
        }

        // Load last touch
        if let savedLastTouch: TouchAttribution = await storage.getCodable(lastTouchKey, type: TouchAttribution.self) {
            if !isExpired(savedLastTouch) {
                lastTouch = savedLastTouch
            } else {
                await storage.removeValue(lastTouchKey)
            }
        }

        // Load journey
        if let savedJourney: [TouchPoint] = await storage.getCodableArray(journeyKey, type: TouchPoint.self) {
            journey = savedJourney
        }

        initialized = true
        debugLog("Journey manager initialized: hasFirstTouch=\(firstTouch != nil), hasLastTouch=\(lastTouch != nil), touchpoints=\(journey.count)")
    }

    // MARK: - Attribution Management

    /// Check if attribution has expired
    private func isExpired(_ attribution: TouchAttribution) -> Bool {
        return Date().timeIntervalSince1970 * 1000 >= attribution.expiresAt
    }

    /// Store first touch attribution (only if not already set or expired)
    public func storeFirstTouch(_ attribution: TouchAttribution) async {
        // Only store if no valid first touch exists
        if let existing = firstTouch, !isExpired(existing) {
            debugLog("First touch already exists, not overwriting")
            return
        }

        let now = Date().timeIntervalSince1970 * 1000
        var newAttribution = attribution
        newAttribution.timestamp = attribution.timestamp > 0 ? attribution.timestamp : now
        newAttribution.capturedAt = now
        newAttribution.expiresAt = now + attributionWindowMs

        firstTouch = newAttribution
        await storage.setCodable(firstTouchKey, value: newAttribution)
        debugLog("First touch stored")
    }

    /// Get first touch attribution (nil if expired)
    public func getFirstTouch() -> TouchAttribution? {
        guard let touch = firstTouch else { return nil }

        if isExpired(touch) {
            firstTouch = nil
            Task { await storage.removeValue(firstTouchKey) }
            return nil
        }

        return touch
    }

    /// Store last touch attribution (always updates)
    public func storeLastTouch(_ attribution: TouchAttribution) async {
        let now = Date().timeIntervalSince1970 * 1000
        var newAttribution = attribution
        newAttribution.timestamp = attribution.timestamp > 0 ? attribution.timestamp : now
        newAttribution.capturedAt = now
        newAttribution.expiresAt = now + attributionWindowMs

        lastTouch = newAttribution
        await storage.setCodable(lastTouchKey, value: newAttribution)
        debugLog("Last touch stored")
    }

    /// Get last touch attribution (nil if expired)
    public func getLastTouch() -> TouchAttribution? {
        guard let touch = lastTouch else { return nil }

        if isExpired(touch) {
            lastTouch = nil
            Task { await storage.removeValue(lastTouchKey) }
            return nil
        }

        return touch
    }

    // MARK: - Journey Tracking

    /// Add a touchpoint to the customer journey
    public func addTouchpoint(sessionId: String, attribution: TouchAttribution) async {
        let touchpoint = TouchPoint(
            timestamp: Date().timeIntervalSince1970 * 1000,
            sessionId: sessionId,
            source: attribution.source,
            medium: attribution.medium,
            campaign: attribution.campaign,
            clickIdType: attribution.clickIdType
        )

        journey.append(touchpoint)

        // Keep only last maxTouchpoints
        if journey.count > maxTouchpoints {
            journey = Array(journey.suffix(maxTouchpoints))
        }

        await storage.setCodableArray(journeyKey, value: journey)
        debugLog("Touchpoint added, total: \(journey.count)")
    }

    /// Get customer journey (all touchpoints)
    public func getJourney() -> [TouchPoint] {
        return journey
    }

    /// Record attribution from a deep link or install
    /// Updates first-touch (if not set), last-touch, and adds touchpoint
    public func recordAttribution(sessionId: String, attribution: TouchAttribution) async {
        // Only process if we have meaningful attribution data
        let hasAttribution = attribution.source != nil ||
                            attribution.clickId != nil ||
                            attribution.campaign != nil ||
                            attribution.lyr != nil

        guard hasAttribution else {
            debugLog("No attribution data to record")
            return
        }

        // Store first touch if not set
        if getFirstTouch() == nil {
            await storeFirstTouch(attribution)
        }

        // Always update last touch
        await storeLastTouch(attribution)

        // Add touchpoint
        await addTouchpoint(sessionId: sessionId, attribution: attribution)
    }

    // MARK: - Attribution Data for Events

    /// Get attribution data for events (mirrors Web SDK format)
    public func getAttributionData() -> [String: Any] {
        let firstTouch = getFirstTouch()
        let lastTouch = getLastTouch()
        let journey = getJourney()

        var data: [String: Any] = [:]

        // First touch
        data["first_touch_source"] = firstTouch?.source
        data["first_touch_medium"] = firstTouch?.medium
        data["first_touch_campaign"] = firstTouch?.campaign
        data["first_touch_timestamp"] = firstTouch?.timestamp
        data["firstTouchSource"] = firstTouch?.source
        data["firstTouchMedium"] = firstTouch?.medium
        data["firstTouchCampaign"] = firstTouch?.campaign

        // Last touch
        data["last_touch_source"] = lastTouch?.source
        data["last_touch_medium"] = lastTouch?.medium
        data["last_touch_campaign"] = lastTouch?.campaign
        data["last_touch_timestamp"] = lastTouch?.timestamp
        data["lastTouchSource"] = lastTouch?.source
        data["lastTouchMedium"] = lastTouch?.medium
        data["lastTouchCampaign"] = lastTouch?.campaign

        // Journey metrics
        data["touchpoint_count"] = journey.count
        data["touchpointCount"] = journey.count

        if let timestamp = firstTouch?.timestamp {
            let days = Int((Date().timeIntervalSince1970 * 1000 - timestamp) / 86400000)
            data["days_since_first_touch"] = days
            data["daysSinceFirstTouch"] = days
        } else {
            data["days_since_first_touch"] = 0
            data["daysSinceFirstTouch"] = 0
        }

        return data
    }

    // MARK: - Journey Summary

    /// Get journey summary for debugging
    public func getJourneySummary() -> JourneySummary {
        let firstTouch = getFirstTouch()
        let journey = getJourney()
        let sources = Array(Set(journey.compactMap { $0.source }))

        var daysSinceFirstTouch = 0
        if let timestamp = firstTouch?.timestamp {
            daysSinceFirstTouch = Int((Date().timeIntervalSince1970 * 1000 - timestamp) / 86400000)
        }

        return JourneySummary(
            hasFirstTouch: firstTouch != nil,
            hasLastTouch: getLastTouch() != nil,
            touchpointCount: journey.count,
            daysSinceFirstTouch: daysSinceFirstTouch,
            sources: sources
        )
    }

    // MARK: - Clear

    /// Clear all journey data (for testing/reset)
    public func clearJourney() async {
        firstTouch = nil
        lastTouch = nil
        journey = []

        await storage.removeValue(firstTouchKey)
        await storage.removeValue(lastTouchKey)
        await storage.removeValue(journeyKey)

        debugLog("Journey data cleared")
    }
}
