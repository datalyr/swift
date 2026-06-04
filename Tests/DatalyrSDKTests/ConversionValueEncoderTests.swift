import XCTest
@testable import DatalyrSDK

// Mixed-model SKAN encoding: fineValue = (funnelRank << 3) | revenueTier, all within 0-63,
// ordered so higher-value/down-funnel events get HIGHER values (SKAN only revises upward).
final class ConversionValueEncoderTests: XCTestCase {

    // MARK: - E-commerce Template Tests

    func testEcommerceTemplate_PurchaseEvent() {
        let encoder = ConversionValueEncoder(template: .ecommerce)

        // purchase rank 7 → base 56; revenue tier fills the low 3 bits.
        let purchaseNoRevenue = encoder.encode(event: "purchase", properties: nil)
        XCTAssertEqual(purchaseNoRevenue, 56) // 7<<3

        let purchaseWithRevenue = encoder.encode(event: "purchase", properties: ["revenue": 5.0])
        XCTAssertEqual(purchaseWithRevenue, 58) // 56 | tier 2

        let purchaseHighRevenue = encoder.encode(event: "purchase", properties: ["revenue": 300.0])
        XCTAssertEqual(purchaseHighRevenue, 63) // 56 | tier 7
    }

    func testEcommerceTemplate_AddToCart() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        XCTAssertEqual(encoder.encode(event: "add_to_cart", properties: nil), 24) // rank 3
    }

    func testEcommerceTemplate_BeginCheckout() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        XCTAssertEqual(encoder.encode(event: "begin_checkout", properties: nil), 32) // rank 4
    }

    func testEcommerceTemplate_Signup() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        // Was 63 (bit 6 overflow). Now rank 2 → 16, well below purchase (56+).
        XCTAssertEqual(encoder.encode(event: "signup", properties: nil), 16)
    }

    func testEcommerceTemplate_Subscribe() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        XCTAssertEqual(encoder.encode(event: "subscribe", properties: nil), 48) // rank 6
        XCTAssertEqual(encoder.encode(event: "subscribe", properties: ["revenue": 50.0]), 53) // 48 | tier 5
    }

    func testEcommerceTemplate_ViewItem() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        // Was 63 (bit 7 overflow). Now rank 1 → 8 (top of funnel = lowest value).
        XCTAssertEqual(encoder.encode(event: "view_item", properties: nil), 8)
    }

    // MARK: - Funnel ordering (the regression for the actual bug)

    func testFunnelOrdering_DownFunnelOutranksUpFunnel() {
        // SKAN only revises the fine value UPWARD, so down-funnel/higher-value events MUST
        // map to higher values — otherwise an early event (signup) locks the value and a
        // later purchase is silently dropped. The old scheme inverted this (signup=63 >
        // purchase=15), so a signup-then-purchase user reported signup forever.
        let e = ConversionValueEncoder(template: .ecommerce)
        let viewItem = e.encode(event: "view_item", properties: nil)
        let signup = e.encode(event: "signup", properties: nil)
        let addToCart = e.encode(event: "add_to_cart", properties: nil)
        let checkout = e.encode(event: "begin_checkout", properties: nil)
        let purchaseLow = e.encode(event: "purchase", properties: ["revenue": 0.0])
        let purchaseHigh = e.encode(event: "purchase", properties: ["revenue": 1000.0])

        XCTAssertTrue(viewItem < signup, "view_item(\(viewItem)) < signup(\(signup))")
        XCTAssertTrue(signup < addToCart, "signup(\(signup)) < add_to_cart(\(addToCart))")
        XCTAssertTrue(addToCart < checkout, "add_to_cart(\(addToCart)) < begin_checkout(\(checkout))")
        XCTAssertTrue(checkout < purchaseLow, "begin_checkout(\(checkout)) < purchase(\(purchaseLow))")
        XCTAssertTrue(purchaseLow <= purchaseHigh, "purchase low-rev <= high-rev")
        // The crucial invariant the bug violated:
        XCTAssertTrue(purchaseLow > signup, "purchase MUST outrank signup so signup can't lock the value")
    }

    // MARK: - Gaming Template Tests

    func testGamingTemplate_LevelComplete() {
        let encoder = ConversionValueEncoder(template: .gaming)
        XCTAssertEqual(encoder.encode(event: "level_complete", properties: nil), 24) // rank 3
    }

    func testGamingTemplate_TutorialComplete() {
        let encoder = ConversionValueEncoder(template: .gaming)
        XCTAssertEqual(encoder.encode(event: "tutorial_complete", properties: nil), 32) // rank 4
    }

    func testGamingTemplate_Purchase() {
        let encoder = ConversionValueEncoder(template: .gaming)
        XCTAssertEqual(encoder.encode(event: "purchase", properties: nil), 56) // rank 7
        XCTAssertEqual(encoder.encode(event: "purchase", properties: ["revenue": 25.0]), 60) // 56 | tier 4
    }

    func testGamingTemplate_AchievementUnlocked() {
        let encoder = ConversionValueEncoder(template: .gaming)
        XCTAssertEqual(encoder.encode(event: "achievement_unlocked", properties: nil), 40) // rank 5 (was 63)
    }

    func testGamingTemplate_SessionStart() {
        let encoder = ConversionValueEncoder(template: .gaming)
        XCTAssertEqual(encoder.encode(event: "session_start", properties: nil), 8) // rank 1 (was 63)
    }

    func testGamingTemplate_AdWatched() {
        let encoder = ConversionValueEncoder(template: .gaming)
        XCTAssertEqual(encoder.encode(event: "ad_watched", properties: nil), 16) // rank 2 (was 63)
    }

    // MARK: - Subscription Template Tests

    func testSubscriptionTemplate_TrialStart() {
        let encoder = ConversionValueEncoder(template: .subscription)
        XCTAssertEqual(encoder.encode(event: "trial_start", properties: nil), 32) // rank 4
    }

    func testSubscriptionTemplate_Subscribe() {
        let encoder = ConversionValueEncoder(template: .subscription)
        XCTAssertEqual(encoder.encode(event: "subscribe", properties: nil), 56) // rank 7
        XCTAssertEqual(encoder.encode(event: "subscribe", properties: ["revenue": 100.0]), 62) // 56 | tier 6
    }

    func testSubscriptionTemplate_Upgrade() {
        let encoder = ConversionValueEncoder(template: .subscription)
        XCTAssertEqual(encoder.encode(event: "upgrade", properties: nil), 48) // rank 6
        XCTAssertEqual(encoder.encode(event: "upgrade", properties: ["revenue": 200.0]), 54) // 48 | tier 6
    }

    func testSubscriptionTemplate_Cancel() {
        let encoder = ConversionValueEncoder(template: .subscription)
        XCTAssertEqual(encoder.encode(event: "cancel", properties: nil), 8) // rank 1 (was 63)
    }

    func testSubscriptionTemplate_PaymentMethodAdded() {
        let encoder = ConversionValueEncoder(template: .subscription)
        XCTAssertEqual(encoder.encode(event: "payment_method_added", properties: nil), 24) // rank 3 (was 63)
    }

    // MARK: - Revenue Tier Tests

    func testRevenueTiers() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        let testCases = [
            (0.5, 0), (2.5, 1), (7.5, 2), (15.0, 3),
            (35.0, 4), (75.0, 5), (150.0, 6), (500.0, 7)
        ]
        for (revenue, expectedTier) in testCases {
            let conversionValue = encoder.encode(event: "purchase", properties: ["revenue": revenue])
            // purchase rank 7 → base 56; tier fills the low 3 bits (no overlap with 56=0b111000).
            XCTAssertEqual(conversionValue, 56 | expectedTier,
                          "Revenue $\(revenue) → tier \(expectedTier) → \(56 | expectedTier)")
        }
    }

    // MARK: - Edge Cases

    func testUnknownEvent() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        XCTAssertEqual(encoder.encode(event: "unknown_event", properties: nil), 0)
    }

    func testNilProperties() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        XCTAssertEqual(encoder.encode(event: "purchase", properties: nil), 56) // rank only, no revenue
    }

    func testEmptyProperties() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        XCTAssertEqual(encoder.encode(event: "purchase", properties: [:]), 56)
    }

    func testNonNumericRevenue() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        XCTAssertEqual(encoder.encode(event: "purchase", properties: ["revenue": "invalid"]), 56)
    }

    func testValueProperty() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        // "value" works as well as "revenue"; $25 → tier 4.
        XCTAssertEqual(encoder.encode(event: "purchase", properties: ["value": 25.0]), 60) // 56 | 4
    }

    func testConversionValueRange() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        let events = ["purchase", "add_to_cart", "begin_checkout", "signup", "subscribe", "view_item"]
        for event in events {
            let value = encoder.encode(event: event, properties: ["revenue": 1000.0])
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 63, "\(event) must be <= 63")
        }
    }

    // MARK: - Performance

    func testEncodingPerformance() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        measure {
            for _ in 0..<10000 {
                _ = encoder.encode(event: "purchase", properties: ["revenue": 29.99])
            }
        }
    }

    // MARK: - Integration

    func testMultipleEventsInSequence() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        let viewItem = encoder.encode(event: "view_item", properties: nil)
        let addToCart = encoder.encode(event: "add_to_cart", properties: nil)
        let checkout = encoder.encode(event: "begin_checkout", properties: nil)
        let purchase = encoder.encode(event: "purchase", properties: ["revenue": 49.99])

        XCTAssertEqual(viewItem, 8)
        XCTAssertEqual(addToCart, 24)
        XCTAssertEqual(checkout, 32)
        XCTAssertEqual(purchase, 60) // 56 | tier 4
        // Monotonic up the funnel → SKAN's upward-only revision captures the purchase.
        XCTAssertTrue(viewItem < addToCart && addToCart < checkout && checkout < purchase)
    }
}
