import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

// MARK: - SKAdNetwork 4.0 Coarse Value
#if os(iOS)
@available(iOS 16.1, *)
public enum SKANCoarseValue: String {
    case low = "low"
    case medium = "medium"
    case high = "high"

    /// Convert to Apple's SKAdNetwork coarse value
    var systemValue: SKAdNetwork.CoarseConversionValue {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}
#else
public enum SKANCoarseValue: String {
    case low = "low"
    case medium = "medium"
    case high = "high"
}
#endif

/// Result from conversion value encoding (SKAN 4.0 compatible)
public struct ConversionResult {
    /// Fine-grained conversion value (0-63)
    public let fineValue: Int
    /// Coarse value for SKAN 4.0 (.low, .medium, .high)
    public let coarseValue: String
    /// Whether to lock the conversion window
    public let lockWindow: Bool
    /// Event priority (higher = more important)
    public let priority: Int
}

// MARK: - Conversion Template Structure
public struct ConversionTemplate {
    let name: String
    let events: [String: EventMapping]

    struct EventMapping {
        // SKAN's fine value is a 6-bit int (0-63) that can ONLY be revised upward, so we
        // use Apple's recommended "mixed model": the HIGH 3 bits hold a funnel rank (0-7,
        // down-funnel = higher) and the LOW 3 bits hold a revenue tier (0-7). Higher-value
        // events therefore get higher fine values, so an early event (e.g. signup) can't
        // lock the value and block a later, higher-value event (e.g. purchase) from
        // registering — the bug in the old independent-bit scheme, where bits 6/7 also
        // overflowed 63.
        let rank: Int             // 0-7 funnel stage → high 3 bits
        let hasRevenue: Bool      // when true, revenue tier fills the low 3 bits
        let priority: Int         // Event priority (higher = more important)
        let coarseValue: String   // SKAN 4.0 coarse value: "low", "medium", "high"
        let lockWindow: Bool      // SKAN 4.0: lock the conversion window after this event

        init(rank: Int, hasRevenue: Bool = false, priority: Int, coarseValue: String = "medium", lockWindow: Bool = false) {
            self.rank = rank
            self.hasRevenue = hasRevenue
            self.priority = priority
            self.coarseValue = coarseValue
            self.lockWindow = lockWindow
        }
    }
}

// MARK: - Conversion Value Encoder
public class ConversionValueEncoder {
    private let template: ConversionTemplate

    init(template: ConversionTemplate) {
        self.template = template
    }

    /// Encode an event into Apple's 0-63 conversion value format (SKAN 3.0 compatible)
    public func encode(event: String, properties: [String: Any]?) -> Int {
        return encodeWithSKAN4(event: event, properties: properties).fineValue
    }

    /// Encode an event with full SKAN 4.0 support (fine value, coarse value, lock window).
    ///
    /// fineValue = (funnelRank << 3) | revenueTier — see EventMapping. The value→meaning
    /// mapping MUST match the SKAN conversion-value schema configured in the ad-network
    /// dashboard (App Store Connect / Meta Events Manager / MMP).
    public func encodeWithSKAN4(event: String, properties: [String: Any]?) -> ConversionResult {
        guard let mapping = template.events[event] else {
            return ConversionResult(fineValue: 0, coarseValue: "low", lockWindow: false, priority: 0)
        }

        // High 3 bits = funnel rank.
        var conversionValue = (mapping.rank & 0x7) << 3

        // Low 3 bits = revenue tier (only for monetary events).
        // FSR-87: read via NSNumber, not `as? Double`. In Swift an `Any` holding a native Int
        // does NOT cast with `as? Double` (only NSNumber-backed values do), so the natural
        // call trackWithSKAdNetwork("purchase", properties: ["revenue": 50]) silently lost its
        // revenue tier. NSNumber bridging catches Int, Double, Float and JSON-decoded numbers.
        // (Bit-packing schema unchanged — IOS-24.)
        var coarseValue = mapping.coarseValue
        if mapping.hasRevenue,
           let properties = properties,
           let revenue = (properties["revenue"] as? NSNumber)?.doubleValue
                       ?? (properties["value"] as? NSNumber)?.doubleValue {
            conversionValue |= getRevenueTier(revenue)
            coarseValue = getCoarseValueForRevenue(revenue)
        }

        // (rank<<3)|tier is already within 0-63 for rank/tier in 0-7; clamp defensively.
        let fineValue = min(max(conversionValue, 0), 63)

        return ConversionResult(
            fineValue: fineValue,
            coarseValue: coarseValue,
            lockWindow: mapping.lockWindow,
            priority: mapping.priority
        )
    }

    /// Map revenue amount to 3-bit tier (0-7)
    private func getRevenueTier(_ revenue: Double) -> Int {
        switch revenue {
        case 0..<1: return 0      // $0-1
        case 1..<5: return 1      // $1-5
        case 5..<10: return 2     // $5-10
        case 10..<25: return 3    // $10-25
        case 25..<50: return 4    // $25-50
        case 50..<100: return 5   // $50-100
        case 100..<250: return 6  // $100-250
        default: return 7         // $250+
        }
    }

    /// Map revenue to SKAN 4.0 coarse value
    private func getCoarseValueForRevenue(_ revenue: Double) -> String {
        switch revenue {
        case 0..<10: return "low"       // $0-10 = low value
        case 10..<50: return "medium"   // $10-50 = medium value
        default: return "high"          // $50+ = high value
        }
    }
}

// MARK: - Industry Templates
//
// Mixed-model fine values (funnelRank << 3 | revenueTier), all within 0-63 and ordered so
// down-funnel/higher-value events get HIGHER values (required: SKAN only revises upward).
// Ranks are a sensible default — tune the event→rank order to your LTV model, and mirror
// the final value→meaning mapping into your SKAN dashboard schema.
extension ConversionTemplate {
    /// E-commerce. view_item 8 · signup/registration/lead 16 · add_to_cart 24 ·
    /// begin_checkout 32 · subscribe 48-55 · purchase 56-63 (+revenue tier in low 3 bits).
    static let ecommerce = ConversionTemplate(
        name: "ecommerce",
        events: [
            "view_item": EventMapping(rank: 1, priority: 10, coarseValue: "low"),
            "signup": EventMapping(rank: 2, priority: 20, coarseValue: "low"),
            "complete_registration": EventMapping(rank: 2, priority: 20, coarseValue: "low"),
            "lead": EventMapping(rank: 2, priority: 20, coarseValue: "low"),
            "add_to_cart": EventMapping(rank: 3, priority: 30, coarseValue: "low"),
            "begin_checkout": EventMapping(rank: 4, priority: 50, coarseValue: "medium"),
            "initiate_checkout": EventMapping(rank: 4, priority: 50, coarseValue: "medium"),
            "subscribe": EventMapping(rank: 6, hasRevenue: true, priority: 90, coarseValue: "high", lockWindow: true),
            "purchase": EventMapping(rank: 7, hasRevenue: true, priority: 100, coarseValue: "high", lockWindow: true)
        ]
    )

    /// Gaming. session_start 8 · ad_watched 16 · level_complete 24 · tutorial_complete 32 ·
    /// achievement_unlocked 40 · purchase 56-63 (+revenue tier).
    static let gaming = ConversionTemplate(
        name: "gaming",
        events: [
            "session_start": EventMapping(rank: 1, priority: 10, coarseValue: "low"),
            "ad_watched": EventMapping(rank: 2, priority: 20, coarseValue: "low"),
            "level_complete": EventMapping(rank: 3, priority: 40, coarseValue: "medium"),
            "tutorial_complete": EventMapping(rank: 4, priority: 60, coarseValue: "medium"),
            "achievement_unlocked": EventMapping(rank: 5, priority: 30, coarseValue: "low"),
            "purchase": EventMapping(rank: 7, hasRevenue: true, priority: 100, coarseValue: "high", lockWindow: true)
        ]
    )

    /// Subscription. cancel 8 · signup/registration/lead 16 · payment_method_added 24 ·
    /// trial_start 32 · upgrade 48-55 · subscribe 56-63 (+revenue tier).
    static let subscription = ConversionTemplate(
        name: "subscription",
        events: [
            "cancel": EventMapping(rank: 1, priority: 20, coarseValue: "low"),
            "signup": EventMapping(rank: 2, priority: 30, coarseValue: "low"),
            "complete_registration": EventMapping(rank: 2, priority: 30, coarseValue: "low"),
            "lead": EventMapping(rank: 2, priority: 30, coarseValue: "low"),
            "payment_method_added": EventMapping(rank: 3, priority: 50, coarseValue: "medium"),
            "trial_start": EventMapping(rank: 4, priority: 70, coarseValue: "medium"),
            "upgrade": EventMapping(rank: 6, hasRevenue: true, priority: 90, coarseValue: "high", lockWindow: true),
            "subscribe": EventMapping(rank: 7, hasRevenue: true, priority: 100, coarseValue: "high", lockWindow: true)
        ]
    )
}
