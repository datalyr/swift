# @datalyr/swift

Official Datalyr SDK for iOS - Server-side attribution tracking and analytics.

[![Swift](https://img.shields.io/badge/Swift-5.0+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B-blue.svg)](https://developer.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Features

- **Server-side tracking** - Secure API key authentication
- **SKAdNetwork** - iOS 14+ attribution with conversion values
- **Attribution tracking** - Deep links, UTM parameters, click IDs
- **Offline queue** - Events saved and retried automatically
- **Session management** - Automatic session tracking
- **Performance** - < 5MB memory, minimal battery impact
- **SwiftUI & UIKit** - Works with both frameworks
- **Identity Resolution** - Persistent anonymous ID for complete user journey tracking

## Installation

### Swift Package Manager (Recommended)

1. In Xcode, select **File → Add Package Dependencies**
2. Enter the repository URL:
   ```
   https://github.com/datalyr/swift
   ```
3. Select version **1.0.2** or later
4. Add **DatalyrSDK** to your target

### CocoaPods

Add to your `Podfile`:
```ruby
pod 'DatalyrSwift', '~> 1.0.2'
```

Then run:
```bash
pod install
```

### Manual Installation

1. Download the SDK from [Releases](https://github.com/datalyr/swift/releases)
2. Drag `Sources/DatalyrSDK` folder into your Xcode project
3. Ensure "Copy items if needed" is checked

## Quick Start

```swift
import DatalyrSDK

// Initialize on app launch
let config = DatalyrConfig(
    apiKey: "dk_your_api_key", // Required - get from Datalyr dashboard
    debug: true // Enable console logs during development
)

try await DatalyrSDK.shared.initialize(config: config)

// Track custom event
await DatalyrSDK.shared.track("Button Clicked", eventData: [
    "button_name": "purchase",
    "value": 99.99
])

// Identify user
await DatalyrSDK.shared.identify("user_123", properties: [
    "email": "user@example.com",
    "plan": "premium"
])
```

## Configuration

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",        // Required
    workspaceId: "",                  // Optional (legacy support)
    useServerTracking: true,           // Default: true
    debug: false,                      // Enable logging
    endpoint: "https://api.datalyr.com", // Don't change
    maxRetries: 3,                     // Retry failed requests
    retryDelay: 1.0,                   // Seconds between retries
    timeout: 15.0,                     // Request timeout
    batchSize: 10,                     // Events per batch
    flushInterval: 10.0,               // Seconds between flushes
    maxQueueSize: 100,                 // Max queued events
    enableAutoEvents: true,            // Track lifecycle
    enableAttribution: true,           // Track attribution
    skadTemplate: "ecommerce"          // SKAdNetwork template
)
```

## Core Methods

### Initialize

```swift
// Basic initialization
try await DatalyrSDK.shared.initialize(config: config)

// With SKAdNetwork
try await DatalyrSDK.initializeWithSKAdNetwork(
    config: config,
    template: "ecommerce" // or "gaming", "subscription"
)
```

### Track Events

```swift
// Simple event
await DatalyrSDK.shared.track("Product Viewed")

// Event with properties
await DatalyrSDK.shared.track("Purchase Completed", eventData: [
    "product_id": "SKU123",
    "product_name": "Premium Subscription",
    "amount": 49.99,
    "currency": "USD"
])
```

### Identify Users

```swift
await DatalyrSDK.shared.identify("user_123", properties: [
    "email": "john@example.com",
    "name": "John Doe",
    "plan": "premium",
    "company": "Acme Inc",
    "created_at": "2024-01-15"
])
```

### Track Screen Views

```swift
await DatalyrSDK.shared.screen("Product Details", properties: [
    "product_id": "SKU123",
    "category": "Electronics"
])
```

## E-commerce Tracking

### Track Purchases

```swift
// Simple purchase with SKAdNetwork
await DatalyrSDK.shared.trackPurchase(
    value: 99.99,
    currency: "USD",
    productId: "premium_subscription"
)

// Detailed purchase event
await DatalyrSDK.shared.track("Purchase Completed", eventData: [
    "order_id": "ORDER123",
    "amount": 149.99,
    "currency": "USD",
    "products": [
        ["id": "SKU1", "name": "Product 1", "price": 99.99],
        ["id": "SKU2", "name": "Product 2", "price": 50.00]
    ],
    "tax": 12.50,
    "shipping": 5.00
])
```

### Track Subscriptions

```swift
await DatalyrSDK.shared.trackSubscription(
    value: 9.99,
    currency: "USD",
    plan: "monthly_pro"
)
```

### Track Revenue

```swift
await DatalyrSDK.shared.trackRevenue("In-App Purchase", properties: [
    "product_id": "coins_1000",
    "amount": 4.99,
    "currency": "USD",
    "quantity": 1
])
```

## SKAdNetwork Support

iOS 14+ attribution with automatic conversion value management:

```swift
// Initialize with SKAdNetwork template
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    skadTemplate: "ecommerce" // Choose your business model
)

try await DatalyrSDK.shared.initialize(config: config)

// Events automatically update conversion values
await DatalyrSDK.shared.trackPurchase(value: 99.99, currency: "USD")

// Test conversion value
let value = DatalyrSDK.shared.getConversionValue(
    for: "purchase",
    properties: ["revenue": 75.00]
)
print("Conversion value: \(value ?? 0)") // 0-63
```

### Template Options

- **ecommerce**: Purchase events, revenue ranges
- **gaming**: Level completion, in-app purchases, retention
- **subscription**: Trial starts, conversions, renewals

## Attribution Tracking

Automatic tracking of:
- Deep links and Universal Links
- UTM parameters
- Platform click IDs (fbclid, gclid, ttclid)
- Install referrer
- Campaign data

```swift
// Get attribution data
let attribution = DatalyrSDK.shared.getAttributionData()
print(attribution.campaign)
print(attribution.source)
print(attribution.medium)

// Set custom attribution
var customAttribution = AttributionData()
customAttribution.campaign = "summer_sale"
customAttribution.source = "facebook"
await DatalyrSDK.shared.setAttributionData(customAttribution)
```

## Identity Resolution (New in v1.1.0)

The SDK includes persistent anonymous IDs for complete user journey tracking:

```swift
// Get anonymous ID (persists across app sessions)
let anonymousId = DatalyrSDK.shared.getAnonymousId()
// Or use global function
let anonymousId = datalyrGetAnonymousId()

// Pass to your backend for attribution preservation
let request = URLRequest(url: URL(string: "https://api.example.com/purchase")!)
request.httpBody = try JSONSerialization.data(withJSONObject: [
    "items": cartItems,
    "anonymous_id": anonymousId  // Links server events to mobile events
])

// Identity is automatically linked when you identify a user
await DatalyrSDK.shared.identify("user_123", properties: [
    "email": "user@example.com"
])
// This creates a $identify event that links anonymous_id to user_id
```

### Key Benefits:
- **Attribution Preservation**: Never lose fbclid, gclid, ttclid, or lyr tracking
- **Complete Journey**: Track users from web → app → server
- **Automatic Linking**: Identity resolution happens automatically

## Session Management

Sessions are automatically managed with 30-minute timeout:

```swift
// Get current session
let session = DatalyrSDK.shared.getCurrentSession()

// Manually end session
await DatalyrSDK.shared.endSession()

// Reset user (logout)
await DatalyrSDK.shared.reset()
```

## Automatic Events

When `enableAutoEvents` is true:

- `app_install` - First app open
- `app_open` - App launches
- `app_background` - App enters background
- `app_foreground` - Returns to foreground
- `app_update` - Version changes
- `session_start` - New session
- `session_end` - Session expires

## SwiftUI Integration

```swift
import SwiftUI
import DatalyrSDK

@main
struct MyApp: App {
    init() {
        Task {
            let config = DatalyrConfig(apiKey: "dk_your_api_key")
            try? await DatalyrSDK.shared.initialize(config: config)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    Task {
                        await DatalyrSDK.shared.track("App Opened")
                    }
                }
        }
    }
}
```

## UIKit Integration

```swift
import UIKit
import DatalyrSDK

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, 
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        Task {
            let config = DatalyrConfig(apiKey: "dk_your_api_key")
            try? await DatalyrSDK.shared.initialize(config: config)
        }
        
        return true
    }
}
```

## Deep Link Handling

```swift
// SwiftUI
.onOpenURL { url in
    Task {
        await DatalyrSDK.shared.track("Deep Link Opened", eventData: [
            "url": url.absoluteString,
            "scheme": url.scheme ?? "",
            "host": url.host ?? ""
        ])
    }
}

// UIKit
func application(_ app: UIApplication, open url: URL, 
                options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    Task {
        await DatalyrSDK.shared.track("Deep Link Opened", eventData: [
            "url": url.absoluteString
        ])
    }
    return true
}
```

## Offline Support

Events are automatically queued when offline:

```swift
// Manually flush queue
await DatalyrSDK.shared.flush()

// Check queue status
let status = DatalyrSDK.shared.getStatus()
print("Queue size: \(status.queueStats.queueSize)")
print("Is online: \(status.queueStats.isOnline)")
```

## Debug Mode

Enable detailed logging:

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    debug: true // Enables console logs
)
```

Debug output includes:
- Event tracking logs
- Network requests
- Queue operations
- Attribution updates
- Error messages

## Privacy & Compliance

### User Consent

```swift
// Track consent
await DatalyrSDK.shared.track("Consent Updated", eventData: [
    "tracking_allowed": false,
    "gdpr_consent": false
])

// Disable tracking
await DatalyrSDK.shared.reset()
```

### App Tracking Transparency (iOS 14.5+)

```swift
import AppTrackingTransparency

ATTrackingManager.requestTrackingAuthorization { status in
    Task {
        await DatalyrSDK.shared.track("ATT Status", eventData: [
            "status": status.rawValue
        ])
    }
}
```

## API Reference

### Initialization
```swift
DatalyrSDK.shared.initialize(config: DatalyrConfig) async throws
DatalyrSDK.initializeWithSKAdNetwork(config: DatalyrConfig, template: String) async throws
```

### Event Tracking
```swift
track(_ eventName: String, eventData: EventData? = nil) async
screen(_ screenName: String, properties: EventData? = nil) async
identify(_ userId: String, properties: UserProperties? = nil) async
alias(_ newUserId: String, previousId: String? = nil) async
```

### Revenue Tracking
```swift
trackPurchase(value: Double, currency: String, productId: String?) async
trackSubscription(value: Double, currency: String, plan: String?) async
trackRevenue(_ eventName: String, properties: EventData?) async
```

### Session Management
```swift
getCurrentSession() -> SessionData?
endSession() async
reset() async
flush() async
```

### Attribution
```swift
getAttributionData() -> AttributionData
setAttributionData(_ data: AttributionData) async
```

### Utilities
```swift
getStatus() -> SDKStatus
getConversionValue(for event: String, properties: EventData?) -> Int?
```

## Troubleshooting

### Events not appearing?
1. Check API key is correct (starts with `dk_`)
2. Enable debug mode to see logs
3. Verify network connectivity
4. Check `getStatus()` for queue info
5. Call `flush()` to force send

### Build errors?
```bash
# Clean build folder
cmd+shift+k in Xcode

# Reset package caches
File → Packages → Reset Package Caches

# Update packages
File → Packages → Update to Latest Package Versions
```

### Authentication errors?
- Get API key from: https://app.datalyr.com/settings/api-keys
- Ensure key is active
- Check key permissions

## Example App

See the [examples](./examples) folder for a complete implementation.

## Migration from Other SDKs

### From AppsFlyer/Adjust
```swift
// AppsFlyer
AppsFlyerLib.shared().logEvent("purchase", withValues: [...])

// Datalyr (similar API)
await DatalyrSDK.shared.track("purchase", eventData: [...])
```

### From Firebase Analytics
```swift
// Firebase
Analytics.logEvent("purchase", parameters: [...])

// Datalyr
await DatalyrSDK.shared.track("purchase", eventData: [...])
```

## Support

- 📧 Email: support@datalyr.com
- 📚 Docs: https://docs.datalyr.com
- 🐛 Issues: https://github.com/datalyr/swift/issues
- 💬 Discord: https://discord.gg/datalyr

## License

MIT © Datalyr

---

Built with ❤️ by [Datalyr](https://datalyr.com)