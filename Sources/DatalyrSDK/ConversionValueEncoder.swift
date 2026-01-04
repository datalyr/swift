import Foundation
import StoreKit

// MARK: - SKAdNetwork 4.0 Coarse Value
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
        let bits: [Int]           // Which bits represent this event
        let revenueBits: [Int]?   // Which bits represent revenue tier
        let priority: Int         // Event priority (higher = more important)
        let coarseValue: String   // SKAN 4.0 coarse value: "low", "medium", "high"
        let lockWindow: Bool      // SKAN 4.0: lock the conversion window after this event

        init(bits: [Int], revenueBits: [Int]? = nil, priority: Int, coarseValue: String = "medium", lockWindow: Bool = false) {
            self.bits = bits
            self.revenueBits = revenueBits
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

    /// Encode an event with full SKAN 4.0 support (fine value, coarse value, lock window)
    public func encodeWithSKAN4(event: String, properties: [String: Any]?) -> ConversionResult {
        guard let mapping = template.events[event] else {
            return ConversionResult(fineValue: 0, coarseValue: "low", lockWindow: false, priority: 0)
        }

        var conversionValue = 0

        // Set event bits
        for bit in mapping.bits {
            conversionValue |= (1 << bit)
        }

        // Set revenue bits if revenue is provided
        var coarseValue = mapping.coarseValue
        if let revenueBits = mapping.revenueBits,
           let properties = properties,
           let revenue = properties["revenue"] as? Double ?? properties["value"] as? Double {
            let revenueTier = getRevenueTier(revenue)
            for (index, bit) in revenueBits.enumerated() {
                if index < 3 && (revenueTier >> index) & 1 == 1 {
                    conversionValue |= (1 << bit)
                }
            }
            // Upgrade coarse value based on revenue
            coarseValue = getCoarseValueForRevenue(revenue)
        }

        // Ensure value is within 0-63 range
        let fineValue = min(conversionValue, 63)

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
extension ConversionTemplate {
    /// E-commerce template - optimized for online stores
    /// SKAN 4.0: purchase locks window, high-value events get "high" coarse value
    static let ecommerce = ConversionTemplate(
        name: "ecommerce",
        events: [
            "purchase": EventMapping(bits: [0], revenueBits: [1, 2, 3], priority: 100, coarseValue: "high", lockWindow: true),
            "add_to_cart": EventMapping(bits: [4], revenueBits: nil, priority: 30, coarseValue: "low"),
            "begin_checkout": EventMapping(bits: [5], revenueBits: nil, priority: 50, coarseValue: "medium"),
            "signup": EventMapping(bits: [6], revenueBits: nil, priority: 20, coarseValue: "low"),
            "subscribe": EventMapping(bits: [0, 1], revenueBits: [2, 3, 4], priority: 90, coarseValue: "high", lockWindow: true),
            "view_item": EventMapping(bits: [7], revenueBits: nil, priority: 10, coarseValue: "low")
        ]
    )

    /// Gaming template - optimized for mobile games
    /// SKAN 4.0: purchase locks window, tutorial completion is medium value
    static let gaming = ConversionTemplate(
        name: "gaming",
        events: [
            "level_complete": EventMapping(bits: [0], revenueBits: nil, priority: 40, coarseValue: "medium"),
            "tutorial_complete": EventMapping(bits: [1], revenueBits: nil, priority: 60, coarseValue: "medium"),
            "purchase": EventMapping(bits: [2], revenueBits: [3, 4, 5], priority: 100, coarseValue: "high", lockWindow: true),
            "achievement_unlocked": EventMapping(bits: [6], revenueBits: nil, priority: 30, coarseValue: "low"),
            "session_start": EventMapping(bits: [7], revenueBits: nil, priority: 10, coarseValue: "low"),
            "ad_watched": EventMapping(bits: [0, 6], revenueBits: nil, priority: 20, coarseValue: "low")
        ]
    )

    /// Subscription template - optimized for subscription apps
    /// SKAN 4.0: subscribe/upgrade lock window, trial is medium value
    static let subscription = ConversionTemplate(
        name: "subscription",
        events: [
            "trial_start": EventMapping(bits: [0], revenueBits: nil, priority: 70, coarseValue: "medium"),
            "subscribe": EventMapping(bits: [1], revenueBits: [2, 3, 4], priority: 100, coarseValue: "high", lockWindow: true),
            "upgrade": EventMapping(bits: [1, 5], revenueBits: [2, 3, 4], priority: 90, coarseValue: "high", lockWindow: true),
            "cancel": EventMapping(bits: [6], revenueBits: nil, priority: 20, coarseValue: "low"),
            "signup": EventMapping(bits: [7], revenueBits: nil, priority: 30, coarseValue: "low"),
            "payment_method_added": EventMapping(bits: [0, 7], revenueBits: nil, priority: 50, coarseValue: "medium")
        ]
    )
} 