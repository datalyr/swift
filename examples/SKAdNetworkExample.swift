import UIKit
import DatalyrSDK

// MARK: - SKAdNetwork Integration Example

class SKAdNetworkExampleViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        
        // Example of initializing with SKAdNetwork
        Task {
            await initializeDatalyrWithSKAdNetwork()
        }
    }
    
    // MARK: - SDK Initialization Examples
    
    /// Example 1: Simple SKAdNetwork initialization
    private func initializeDatalyrWithSKAdNetwork() async {
        do {
            // Initialize with SKAdNetwork for e-commerce apps
            try await DatalyrSDK.configureWithSKAdNetwork(
                workspaceId: "your-workspace-id",
                apiKey: "your-api-key",
                template: "ecommerce",
                debug: true
            )
            
            print("✅ Datalyr SDK initialized with SKAdNetwork support")
            
        } catch {
            print("❌ Failed to initialize SDK: \(error)")
        }
    }
    
    /// Example 2: Advanced SKAdNetwork initialization
    private func initializeAdvancedSKAdNetwork() async {
        do {
            // For gaming apps
            try await DatalyrSDK.initializeWithSKAdNetwork(
                config: DatalyrConfig(
                    workspaceId: "your-workspace-id",
                    apiKey: "your-api-key",
                    debug: true,
                    enableAutoEvents: true,
                    enableAttribution: true,
                    skadTemplate: "gaming"
                ),
                template: "gaming"
            )
            
            print("✅ Gaming SDK initialized with SKAdNetwork")
            
        } catch {
            print("❌ Failed to initialize gaming SDK: \(error)")
        }
    }
    
    // MARK: - SKAdNetwork Event Tracking Examples
    
    /// Example 3: E-commerce Events
    @IBAction func ecommerceExamples() {
        Task {
            // Track product view (no revenue)
            await DatalyrSDK.trackWithSKAdNetwork("view_item", eventData: [
                "product_id": "shirt_001",
                "product_name": "Blue Cotton Shirt",
                "category": "clothing",
                "price": 29.99
            ])
            
            // Track add to cart
            await DatalyrSDK.trackWithSKAdNetwork("add_to_cart", eventData: [
                "product_id": "shirt_001",
                "quantity": 1,
                "value": 29.99
            ])
            
            // Track checkout
            await DatalyrSDK.trackWithSKAdNetwork("begin_checkout", eventData: [
                "cart_value": 89.97,
                "item_count": 3
            ])
            
            // Track purchase with revenue (will encode revenue tier)
            await DatalyrSDK.trackPurchase(
                value: 89.97,
                currency: "USD",
                productId: "order_12345"
            )
            
            // Track subscription
            await DatalyrSDK.trackSubscription(
                value: 9.99,
                currency: "USD",
                plan: "monthly"
            )
            
            print("🛒 E-commerce events tracked with SKAdNetwork")
        }
    }
    
    /// Example 4: Gaming Events
    @IBAction func gamingExamples() {
        Task {
            // Track tutorial completion
            await DatalyrSDK.trackWithSKAdNetwork("tutorial_complete", eventData: [
                "tutorial_step": "final",
                "time_spent": 180
            ])
            
            // Track level completion
            await DatalyrSDK.trackWithSKAdNetwork("level_complete", eventData: [
                "level": 5,
                "score": 1250,
                "time": 65
            ])
            
            // Track achievement
            await DatalyrSDK.trackWithSKAdNetwork("achievement_unlocked", eventData: [
                "achievement_id": "first_win",
                "achievement_name": "First Victory"
            ])
            
            // Track in-app purchase
            await DatalyrSDK.trackPurchase(
                value: 4.99,
                currency: "USD",
                productId: "extra_lives"
            )
            
            // Track ad watched
            await DatalyrSDK.trackWithSKAdNetwork("ad_watched", eventData: [
                "ad_type": "rewarded_video",
                "reward": "50_coins"
            ])
            
            print("🎮 Gaming events tracked with SKAdNetwork")
        }
    }
    
    /// Example 5: Subscription App Events
    @IBAction func subscriptionExamples() {
        Task {
            // Track trial start
            await DatalyrSDK.trackWithSKAdNetwork("trial_start", eventData: [
                "trial_duration": 7,
                "plan_type": "premium"
            ])
            
            // Track subscription with revenue
            await DatalyrSDK.trackSubscription(
                value: 19.99,
                currency: "USD",
                plan: "premium_monthly"
            )
            
            // Track upgrade
            await DatalyrSDK.trackWithSKAdNetwork("upgrade", eventData: [
                "revenue": 39.99,
                "from_plan": "basic",
                "to_plan": "premium",
                "currency": "USD"
            ])
            
            // Track cancellation
            await DatalyrSDK.trackWithSKAdNetwork("cancel", eventData: [
                "plan": "premium_monthly",
                "reason": "price_too_high"
            ])
            
            print("📱 Subscription events tracked with SKAdNetwork")
        }
    }
    
    // MARK: - Testing & Debugging Examples
    
    /// Example 6: Testing Conversion Values
    @IBAction func testConversionValues() {
        // Test conversion values without sending to Apple
        let purchaseValue = DatalyrSDK.getConversionValue(for: "purchase", properties: [
            "revenue": 29.99
        ])
        
        let cartValue = DatalyrSDK.getConversionValue(for: "add_to_cart", properties: nil)
        
        let subscriptionValue = DatalyrSDK.getConversionValue(for: "subscribe", properties: [
            "revenue": 9.99
        ])
        
        print("🧪 Testing Conversion Values:")
        print("Purchase ($29.99): \(purchaseValue ?? 0)")
        print("Add to Cart: \(cartValue ?? 0)")
        print("Subscription ($9.99): \(subscriptionValue ?? 0)")
        
        // Test revenue tiers
        testRevenueTiers()
    }
    
    private func testRevenueTiers() {
        let testValues = [0.5, 2.50, 7.99, 15.00, 35.00, 75.00, 150.00, 500.00]
        
        print("💰 Revenue Tier Testing:")
        for value in testValues {
            let conversionValue = DatalyrSDK.getConversionValue(for: "purchase", properties: [
                "revenue": value
            ])
            print("$\(value) → Conversion Value: \(conversionValue ?? 0)")
        }
    }
    
    // MARK: - Global Function Examples
    
    /// Example 7: Using Global Convenience Functions
    @IBAction func globalFunctionExamples() {
        Task {
            // Use global functions for simpler syntax
            await datalyrTrackWithSKAdNetwork("signup", properties: [
                "source": "homepage",
                "method": "email"
            ])
            
            await datalyrTrackPurchase(value: 49.99, productId: "premium_upgrade")
            
            await datalyrTrackSubscription(value: 12.99, plan: "pro_monthly")
            
            // Test conversion value
            let testValue = datalyrGetConversionValue(for: "purchase", properties: ["revenue": 25.00])
            print("Global function test - Conversion value: \(testValue ?? 0)")
        }
    }
    
    // MARK: - Error Handling & Validation
    
    /// Example 8: Error Handling
    @IBAction func errorHandlingExample() {
        Task {
            // Check if SDK is initialized
            guard DatalyrSDK.shared.isInitialized else {
                print("❌ SDK not initialized")
                return
            }
            
            // Track with error handling
            do {
                await DatalyrSDK.trackWithSKAdNetwork("test_event", eventData: [
                    "revenue": 15.99,
                    "product": "test_product"
                ])
                print("✅ Event tracked successfully")
            } catch {
                print("❌ Error tracking event: \(error)")
            }
            
            // Get SDK status
            let status = DatalyrSDK.shared.getStatus()
            print("📊 SDK Status:")
            print("  - Initialized: \(status.initialized)")
            print("  - Workspace ID: \(status.workspaceId)")
            print("  - Visitor ID: \(status.visitorId)")
            print("  - Queue Size: \(status.queueStats.queueSize)")
        }
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "SKAdNetwork Example"
        
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        let buttons = [
            createButton("E-commerce Events", action: #selector(ecommerceExamples)),
            createButton("Gaming Events", action: #selector(gamingExamples)),
            createButton("Subscription Events", action: #selector(subscriptionExamples)),
            createButton("Test Conversion Values", action: #selector(testConversionValues)),
            createButton("Global Functions", action: #selector(globalFunctionExamples)),
            createButton("Error Handling", action: #selector(errorHandlingExample))
        ]
        
        buttons.forEach { stackView.addArrangedSubview($0) }
        
        view.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])
    }
    
    private func createButton(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
}

// MARK: - AppDelegate Integration Example

extension AppDelegate {
    func configureDatalyrSKAdNetwork() {
        Task {
            do {
                // Configure based on your app type
                try await DatalyrSDK.configureWithSKAdNetwork(
                    workspaceId: "your-workspace-id",
                    apiKey: "your-api-key",
                    template: "ecommerce", // or "gaming" or "subscription"
                    debug: true,
                    enableAutoEvents: true,
                    enableAttribution: true
                )
            } catch {
                print("Failed to configure Datalyr SDK: \(error)")
            }
        }
    }
}

// MARK: - SwiftUI Integration Example

#if canImport(SwiftUI)
import SwiftUI

@available(iOS 13.0, *)
struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Button("Track Purchase") {
                Task {
                    await datalyrTrackPurchase(value: 29.99, productId: "premium_feature")
                }
            }
            
            Button("Track Subscription") {
                Task {
                    await datalyrTrackSubscription(value: 9.99, plan: "monthly")
                }
            }
            
            Button("Test Conversion Value") {
                let value = datalyrGetConversionValue(for: "purchase", properties: ["revenue": 50.0])
                print("Conversion value: \(value ?? 0)")
            }
        }
        .datalyrScreen("main_screen") // Automatic screen tracking
        .padding()
    }
}
#endif 