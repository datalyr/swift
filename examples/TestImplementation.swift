import SwiftUI
import DatalyrSDK

struct TestImplementationView: View {
    @State private var statusText = "SDK not initialized"
    @State private var isInitialized = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Datalyr SDK v1.0.0 Test")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Server-Side Tracking API")
                    .font(.headline)
                    .foregroundColor(.gray)
                
                Text(statusText)
                    .font(.caption)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                
                VStack(spacing: 15) {
                    Button("Initialize SDK") {
                        Task { await initializeSDK() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(isInitialized)
                    
                    Button("Identify User") {
                        Task { await testUserIdentification() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                    
                    Button("Track Event") {
                        Task { await testEventTracking() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                    
                    Button("Track Purchase") {
                        Task { await testPurchaseTracking() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                    
                    Button("Track Screen") {
                        Task { await testScreenTracking() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                    
                    Button("Test Attribution") {
                        Task { await testAttributionData() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                    
                    Button("Track Revenue") {
                        Task { await testRevenue() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                    
                    Button("Flush Events") {
                        Task { await testFlush() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                    
                    Button("Reset Session") {
                        Task { await testReset() }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                    
                    Button("Get Status") {
                        getStatus()
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!isInitialized)
                }
                .padding()
            }
            .padding()
        }
    }
    
    // MARK: - Test Functions
    
    func initializeSDK() async {
        do {
            // Initialize SDK with server-side API
            let config = DatalyrConfig(
                apiKey: "dk_your_api_key_here", // Required for v1.0.0
                workspaceId: "", // Now optional
                useServerTracking: true, // Default: true (uses https://api.datalyr.com)
                debug: true,
                endpoint: "https://api.datalyr.com",
                enableAutoEvents: true,
                enableAttribution: true,
                skadTemplate: "ecommerce" // For SKAdNetwork support
            )
            
            try await DatalyrSDK.shared.initialize(config: config)
            
            statusText = "SDK initialized with server-side tracking"
            isInitialized = true
            
            // Track app open event
            await DatalyrSDK.shared.track("App Opened", eventData: [
                "version": "1.0.0",
                "source": "test_implementation"
            ])
            
        } catch {
            statusText = "Initialization failed: \(error.localizedDescription)"
        }
    }
    
    func testUserIdentification() async {
        await DatalyrSDK.shared.identify("test_user_123", properties: [
            "email": "user@example.com",
            "name": "Test User",
            "plan": "premium",
            "company": "Test Company"
        ])
        statusText = "User identified: test_user_123"
    }
    
    func testEventTracking() async {
        // Standard event tracking
        await DatalyrSDK.shared.track("Button Clicked", eventData: [
            "button_name": "test_button",
            "screen": "test_screen"
        ])
        
        statusText = "Event tracked: Button Clicked"
    }
    
    func testPurchaseTracking() async {
        // Track purchase with automatic SKAdNetwork conversion
        await DatalyrSDK.shared.trackPurchase(
            value: 99.99,
            currency: "USD",
            productId: "premium_subscription"
        )
        
        statusText = "Purchase tracked with SKAdNetwork: $99.99"
    }
    
    func testScreenTracking() async {
        await DatalyrSDK.shared.screen("Test Screen", properties: [
            "previous_screen": "Home",
            "user_action": "navigation"
        ])
        
        statusText = "Screen view tracked: Test Screen"
    }
    
    func testAttributionData() async {
        // Set custom attribution data
        var attribution = AttributionData()
        attribution.campaignName = "summer_sale"
        attribution.campaignSource = "facebook"
        attribution.campaignMedium = "social"
        attribution.fbclid = "test_fbclid_123"
        
        await DatalyrSDK.shared.setAttributionData(attribution)
        
        // Get current attribution
        let currentAttribution = DatalyrSDK.shared.getAttributionData()
        statusText = "Attribution set: \(currentAttribution.campaignName ?? "none")"
    }
    
    func testRevenue() async {
        // Track subscription
        await DatalyrSDK.shared.trackSubscription(
            value: 49.99,
            currency: "USD",
            plan: "monthly_pro"
        )
        
        // Track custom revenue event
        await DatalyrSDK.shared.trackRevenue("In-App Purchase", properties: [
            "product_id": "coins_1000",
            "amount": 4.99,
            "currency": "USD",
            "quantity": 1
        ])
        
        statusText = "Revenue events tracked"
    }
    
    func testFlush() async {
        // Force flush all queued events
        await DatalyrSDK.shared.flush()
        statusText = "Events flushed to server"
    }
    
    func testReset() async {
        // Reset user session (logout)
        await DatalyrSDK.shared.reset()
        statusText = "User session reset"
    }
    
    func getStatus() {
        let status = DatalyrSDK.shared.getStatus()
        statusText = """
        SDK Status:
        Initialized: \(status.initialized)
        Visitor ID: \(String(status.visitorId.prefix(8)))...
        Session ID: \(String(status.sessionId.prefix(8)))...
        User ID: \(status.currentUserId ?? "anonymous")
        Queue Size: \(status.queueStats.queueSize)
        """
    }
}

// MARK: - Button Style

struct TestButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding()
            .background(configuration.isPressed ? Color.blue.opacity(0.8) : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

// MARK: - App Entry Point

@main
struct TestApp: App {
    var body: some Scene {
        WindowGroup {
            TestImplementationView()
        }
    }
}

// MARK: - Alternative UIKit Implementation

import UIKit

class TestViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        Task {
            await initializeSDK()
            await runAllTests()
        }
    }
    
    func initializeSDK() async {
        do {
            // Using the static initialization method with SKAdNetwork
            try await DatalyrSDK.initializeWithSKAdNetwork(
                config: DatalyrConfig(
                    apiKey: "dk_your_api_key_here",
                    workspaceId: "", // Optional
                    useServerTracking: true,
                    debug: true
                ),
                template: "ecommerce"
            )
            
            print("✅ SDK initialized with server-side tracking")
            
        } catch {
            print("❌ Initialization failed: \(error)")
        }
    }
    
    func runAllTests() async {
        // Test 1: Identify user
        await DatalyrSDK.shared.identify("test_user_ios", properties: [
            "platform": "iOS",
            "app_version": "1.0.0"
        ])
        print("✅ User identified")
        
        // Test 2: Track custom event
        await DatalyrSDK.trackWithSKAdNetwork("Test Event", eventData: [
            "test_id": "123",
            "timestamp": Date().timeIntervalSince1970
        ])
        print("✅ Event tracked with SKAdNetwork")
        
        // Test 3: Track purchase
        await DatalyrSDK.trackPurchase(
            value: 19.99,
            currency: "USD",
            productId: "test_product"
        )
        print("✅ Purchase tracked")
        
        // Test 4: Track subscription
        await DatalyrSDK.trackSubscription(
            value: 9.99,
            currency: "USD",
            plan: "monthly"
        )
        print("✅ Subscription tracked")
        
        // Test 5: Get conversion value
        if let conversionValue = DatalyrSDK.getConversionValue(
            for: "purchase",
            properties: ["revenue": 50.0]
        ) {
            print("✅ Conversion value: \(conversionValue)")
        }
        
        // Test 6: Get status
        let status = DatalyrSDK.shared.getStatus()
        print("✅ SDK Status:")
        print("  - Initialized: \(status.initialized)")
        print("  - Queue size: \(status.queueStats.queueSize)")
        print("  - User ID: \(status.currentUserId ?? "anonymous")")
        
        // Test 7: Flush events
        await DatalyrSDK.shared.flush()
        print("✅ Events flushed")
    }
}