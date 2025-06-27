import XCTest
@testable import DatalyrSDK

final class ConversionValueEncoderTests: XCTestCase {
    
    // MARK: - E-commerce Template Tests
    
    func testEcommerceTemplate_PurchaseEvent() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        // Test purchase without revenue
        let purchaseNoRevenue = encoder.encode(event: "purchase", properties: nil)
        XCTAssertEqual(purchaseNoRevenue, 1) // bit 0 = 1
        
        // Test purchase with revenue $5 (tier 2)
        let purchaseWithRevenue = encoder.encode(event: "purchase", properties: ["revenue": 5.0])
        XCTAssertEqual(purchaseWithRevenue, 5) // bit 0 + bit 2 = 1 + 4 = 5
        
        // Test purchase with high revenue $300 (tier 7)
        let purchaseHighRevenue = encoder.encode(event: "purchase", properties: ["revenue": 300.0])
        XCTAssertEqual(purchaseHighRevenue, 15) // bits 0,1,2,3 = 1 + 2 + 4 + 8 = 15
    }
    
    func testEcommerceTemplate_AddToCart() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        let addToCart = encoder.encode(event: "add_to_cart", properties: nil)
        XCTAssertEqual(addToCart, 16) // bit 4 = 16
    }
    
    func testEcommerceTemplate_BeginCheckout() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        let checkout = encoder.encode(event: "begin_checkout", properties: nil)
        XCTAssertEqual(checkout, 32) // bit 5 = 32
    }
    
    func testEcommerceTemplate_Signup() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        let signup = encoder.encode(event: "signup", properties: nil)
        XCTAssertEqual(signup, 63) // bit 6 = 64, but capped at 63
        
        // Test with 63 limit
        XCTAssertLessThanOrEqual(signup, 63)
    }
    
    func testEcommerceTemplate_Subscribe() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        // Subscribe combines bits 0 and 1, plus revenue bits 2,3,4
        let subscribeNoRevenue = encoder.encode(event: "subscribe", properties: nil)
        XCTAssertEqual(subscribeNoRevenue, 3) // bits 0,1 = 3
        
        let subscribeWithRevenue = encoder.encode(event: "subscribe", properties: ["revenue": 50.0])
        XCTAssertEqual(subscribeWithRevenue, 23) // bits 0,1,2,4 = 3 + 4 + 16 = 23 (tier 5)
    }
    
    func testEcommerceTemplate_ViewItem() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        let viewItem = encoder.encode(event: "view_item", properties: nil)
        XCTAssertEqual(viewItem, 63) // bit 7 = 128, but capped at 63
    }
    
    // MARK: - Gaming Template Tests
    
    func testGamingTemplate_LevelComplete() {
        let encoder = ConversionValueEncoder(template: .gaming)
        
        let levelComplete = encoder.encode(event: "level_complete", properties: nil)
        XCTAssertEqual(levelComplete, 1) // bit 0 = 1
    }
    
    func testGamingTemplate_TutorialComplete() {
        let encoder = ConversionValueEncoder(template: .gaming)
        
        let tutorialComplete = encoder.encode(event: "tutorial_complete", properties: nil)
        XCTAssertEqual(tutorialComplete, 2) // bit 1 = 2
    }
    
    func testGamingTemplate_Purchase() {
        let encoder = ConversionValueEncoder(template: .gaming)
        
        let purchaseNoRevenue = encoder.encode(event: "purchase", properties: nil)
        XCTAssertEqual(purchaseNoRevenue, 4) // bit 2 = 4
        
        let purchaseWithRevenue = encoder.encode(event: "purchase", properties: ["revenue": 25.0])
        XCTAssertEqual(purchaseWithRevenue, 36) // bits 2,5 = 4 + 32 = 36 (tier 4)
    }
    
    func testGamingTemplate_AchievementUnlocked() {
        let encoder = ConversionValueEncoder(template: .gaming)
        
        let achievement = encoder.encode(event: "achievement_unlocked", properties: nil)
        XCTAssertEqual(achievement, 63) // bit 6 = 64, capped at 63
    }
    
    func testGamingTemplate_SessionStart() {
        let encoder = ConversionValueEncoder(template: .gaming)
        
        let sessionStart = encoder.encode(event: "session_start", properties: nil)
        XCTAssertEqual(sessionStart, 63) // bit 7 = 128, capped at 63
    }
    
    func testGamingTemplate_AdWatched() {
        let encoder = ConversionValueEncoder(template: .gaming)
        
        let adWatched = encoder.encode(event: "ad_watched", properties: nil)
        XCTAssertEqual(adWatched, 63) // bits 0,6 = 1 + 64 = 65, capped at 63
    }
    
    // MARK: - Subscription Template Tests
    
    func testSubscriptionTemplate_TrialStart() {
        let encoder = ConversionValueEncoder(template: .subscription)
        
        let trialStart = encoder.encode(event: "trial_start", properties: nil)
        XCTAssertEqual(trialStart, 1) // bit 0 = 1
    }
    
    func testSubscriptionTemplate_Subscribe() {
        let encoder = ConversionValueEncoder(template: .subscription)
        
        let subscribeNoRevenue = encoder.encode(event: "subscribe", properties: nil)
        XCTAssertEqual(subscribeNoRevenue, 2) // bit 1 = 2
        
        let subscribeWithRevenue = encoder.encode(event: "subscribe", properties: ["revenue": 100.0])
        XCTAssertEqual(subscribeWithRevenue, 26) // bits 1,3,4 = 2 + 8 + 16 = 26 (tier 6)
    }
    
    func testSubscriptionTemplate_Upgrade() {
        let encoder = ConversionValueEncoder(template: .subscription)
        
        let upgradeNoRevenue = encoder.encode(event: "upgrade", properties: nil)
        XCTAssertEqual(upgradeNoRevenue, 34) // bits 1,5 = 2 + 32 = 34
        
        let upgradeWithRevenue = encoder.encode(event: "upgrade", properties: ["revenue": 200.0])
        XCTAssertEqual(upgradeWithRevenue, 58) // bits 1,5,3,4 = 2 + 32 + 8 + 16 = 58 (tier 6)
    }
    
    func testSubscriptionTemplate_Cancel() {
        let encoder = ConversionValueEncoder(template: .subscription)
        
        let cancel = encoder.encode(event: "cancel", properties: nil)
        XCTAssertEqual(cancel, 63) // bit 6 = 64, capped at 63
    }
    
    func testSubscriptionTemplate_PaymentMethodAdded() {
        let encoder = ConversionValueEncoder(template: .subscription)
        
        let paymentMethod = encoder.encode(event: "payment_method_added", properties: nil)
        XCTAssertEqual(paymentMethod, 63) // bits 0,7 = 1 + 128 = 129, capped at 63
    }
    
    // MARK: - Revenue Tier Tests
    
    func testRevenueTiers() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        // Test all revenue tiers
        let testCases = [
            (0.5, 0),    // $0-1 → tier 0
            (2.5, 1),    // $1-5 → tier 1
            (7.5, 2),    // $5-10 → tier 2
            (15.0, 3),   // $10-25 → tier 3
            (35.0, 4),   // $25-50 → tier 4
            (75.0, 5),   // $50-100 → tier 5
            (150.0, 6),  // $100-250 → tier 6
            (500.0, 7)   // $250+ → tier 7
        ]
        
        for (revenue, expectedTier) in testCases {
            let conversionValue = encoder.encode(event: "purchase", properties: ["revenue": revenue])
            
            // Purchase event uses bit 0 (value 1) + revenue bits 1,2,3
            let expectedValue = 1 + (expectedTier & 1) * 2 + (expectedTier >> 1 & 1) * 4 + (expectedTier >> 2 & 1) * 8
            
            XCTAssertEqual(conversionValue, expectedValue, 
                          "Revenue $\(revenue) should map to tier \(expectedTier) with conversion value \(expectedValue)")
        }
    }
    
    // MARK: - Edge Cases
    
    func testUnknownEvent() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        let unknown = encoder.encode(event: "unknown_event", properties: nil)
        XCTAssertEqual(unknown, 0)
    }
    
    func testNilProperties() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        let purchase = encoder.encode(event: "purchase", properties: nil)
        XCTAssertEqual(purchase, 1) // Only event bit, no revenue
    }
    
    func testEmptyProperties() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        let purchase = encoder.encode(event: "purchase", properties: [:])
        XCTAssertEqual(purchase, 1) // Only event bit, no revenue
    }
    
    func testNonNumericRevenue() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        let purchase = encoder.encode(event: "purchase", properties: ["revenue": "invalid"])
        XCTAssertEqual(purchase, 1) // Only event bit, revenue ignored
    }
    
    func testValueProperty() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        // Test that "value" property works as well as "revenue"
        let purchase = encoder.encode(event: "purchase", properties: ["value": 25.0])
        XCTAssertEqual(purchase, 9) // bit 0 + bit 3 = 1 + 8 = 9 (tier 4)
    }
    
    func testConversionValueRange() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        // Test various events to ensure all values are 0-63
        let events = ["purchase", "add_to_cart", "begin_checkout", "signup", "subscribe", "view_item"]
        
        for event in events {
            let value = encoder.encode(event: event, properties: ["revenue": 1000.0])
            XCTAssertGreaterThanOrEqual(value, 0, "Conversion value should be >= 0")
            XCTAssertLessThanOrEqual(value, 63, "Conversion value should be <= 63")
        }
    }
    
    // MARK: - Performance Tests
    
    func testEncodingPerformance() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        measure {
            for _ in 0..<10000 {
                _ = encoder.encode(event: "purchase", properties: ["revenue": 29.99])
            }
        }
    }
    
    // MARK: - Integration Tests
    
    func testMultipleEventsInSequence() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        
        // Simulate a user journey
        let viewItem = encoder.encode(event: "view_item", properties: nil)
        let addToCart = encoder.encode(event: "add_to_cart", properties: nil)
        let checkout = encoder.encode(event: "begin_checkout", properties: nil)
        let purchase = encoder.encode(event: "purchase", properties: ["revenue": 49.99])
        
        XCTAssertEqual(viewItem, 63) // bit 7 capped
        XCTAssertEqual(addToCart, 16) // bit 4
        XCTAssertEqual(checkout, 32) // bit 5
        XCTAssertEqual(purchase, 9) // bits 0,3 = 1 + 8 = 9 (tier 4)
        
        // All should be valid conversion values
        XCTAssertLessThanOrEqual(viewItem, 63)
        XCTAssertLessThanOrEqual(addToCart, 63)
        XCTAssertLessThanOrEqual(checkout, 63)
        XCTAssertLessThanOrEqual(purchase, 63)
    }
} 