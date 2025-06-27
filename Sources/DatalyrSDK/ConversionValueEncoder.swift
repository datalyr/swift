import Foundation
import StoreKit

// MARK: - Conversion Template Structure
public struct ConversionTemplate {
    let name: String
    let events: [String: EventMapping]
    
    struct EventMapping {
        let bits: [Int]           // Which bits represent this event
        let revenueBits: [Int]?   // Which bits represent revenue tier
        let priority: Int         // Event priority (higher = more important)
    }
}

// MARK: - Conversion Value Encoder
public class ConversionValueEncoder {
    private let template: ConversionTemplate
    
    init(template: ConversionTemplate) {
        self.template = template
    }
    
    /// Encode an event into Apple's 0-63 conversion value format
    public func encode(event: String, properties: [String: Any]?) -> Int {
        guard let mapping = template.events[event] else {
            return 0 // Unknown event
        }
        
        var conversionValue = 0
        
        // Set event bits
        for bit in mapping.bits {
            conversionValue |= (1 << bit)
        }
        
        // Set revenue bits if revenue is provided
        if let revenueBits = mapping.revenueBits,
           let properties = properties,
           let revenue = properties["revenue"] as? Double ?? properties["value"] as? Double {
            let revenueTier = getRevenueTier(revenue)
            for (index, bit) in revenueBits.enumerated() {
                if index < 3 && (revenueTier >> index) & 1 == 1 {
                    conversionValue |= (1 << bit)
                }
            }
        }
        
        // Ensure value is within 0-63 range
        return min(conversionValue, 63)
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
}

// MARK: - Industry Templates
extension ConversionTemplate {
    /// E-commerce template - optimized for online stores
    static let ecommerce = ConversionTemplate(
        name: "ecommerce",
        events: [
            "purchase": EventMapping(bits: [0], revenueBits: [1, 2, 3], priority: 100),
            "add_to_cart": EventMapping(bits: [4], revenueBits: nil, priority: 30),
            "begin_checkout": EventMapping(bits: [5], revenueBits: nil, priority: 50),
            "signup": EventMapping(bits: [6], revenueBits: nil, priority: 20),
            "subscribe": EventMapping(bits: [0, 1], revenueBits: [2, 3, 4], priority: 90),
            "view_item": EventMapping(bits: [7], revenueBits: nil, priority: 10)
        ]
    )
    
    /// Gaming template - optimized for mobile games
    static let gaming = ConversionTemplate(
        name: "gaming",
        events: [
            "level_complete": EventMapping(bits: [0], revenueBits: nil, priority: 40),
            "tutorial_complete": EventMapping(bits: [1], revenueBits: nil, priority: 60),
            "purchase": EventMapping(bits: [2], revenueBits: [3, 4, 5], priority: 100),
            "achievement_unlocked": EventMapping(bits: [6], revenueBits: nil, priority: 30),
            "session_start": EventMapping(bits: [7], revenueBits: nil, priority: 10),
            "ad_watched": EventMapping(bits: [0, 6], revenueBits: nil, priority: 20)
        ]
    )
    
    /// Subscription template - optimized for subscription apps
    static let subscription = ConversionTemplate(
        name: "subscription",
        events: [
            "trial_start": EventMapping(bits: [0], revenueBits: nil, priority: 70),
            "subscribe": EventMapping(bits: [1], revenueBits: [2, 3, 4], priority: 100),
            "upgrade": EventMapping(bits: [1, 5], revenueBits: [2, 3, 4], priority: 90),
            "cancel": EventMapping(bits: [6], revenueBits: nil, priority: 20),
            "signup": EventMapping(bits: [7], revenueBits: nil, priority: 30),
            "payment_method_added": EventMapping(bits: [0, 7], revenueBits: nil, priority: 50)
        ]
    )
} 