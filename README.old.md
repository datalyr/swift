# Datalyr iOS SDK

A powerful, privacy-first iOS SDK for event tracking and analytics. Built with Swift and designed for modern iOS applications.

[![Swift 5.5+](https://img.shields.io/badge/Swift-5.5+-orange.svg)](https://swift.org)
[![iOS 13.0+](https://img.shields.io/badge/iOS-13.0+-blue.svg)](https://developer.apple.com/ios/)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

## Features

- 🚀 **Easy Integration** - Simple Swift Package Manager installation
- 📊 **SKAdNetwork Support** - Automatic conversion value encoding for iOS 14+ attribution
- 🎮 **Industry Templates** - Pre-built templates for E-commerce, Gaming, and Subscription apps
- 🔒 **Privacy First** - No IDFA required, GDPR compliant
- 📱 **Native iOS** - Built specifically for iOS with Swift
- 🌐 **Offline Support** - Events queued and sent when online
- 🎯 **Attribution Tracking** - Deep link and campaign attribution
- 🔄 **Auto Events** - Automatic session and screen tracking
- ⚡ **High Performance** - Minimal impact on app performance
- 🛡️ **Type Safe** - Full Swift type safety and error handling

## Installation

### Swift Package Manager

Add the Datalyr iOS SDK to your project using Xcode:

1. Open your project in Xcode
2. Go to **File → Add Package Dependencies**
3. Enter the repository URL:
   ```
   https://github.com/datalyr/datalyr-ios-sdk
   ```
4. Choose the latest version and add to your target

### Manual Installation

You can also add the SDK manually by downloading the source and adding it to your project.

## Quick Start

### 1. Initialize the SDK

```swift
import DatalyrSDK

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        Task {
            do {
                let config = DatalyrConfig(
                    workspaceId: "YOUR_WORKSPACE_ID",
                    apiKey: "YOUR_API_KEY",
                    debug: false // Set to true for development
                )
                
                try await DatalyrSDK.shared.initialize(config: config)
                print("Datalyr SDK initialized successfully")
            } catch {
                print("Failed to initialize Datalyr SDK: \(error)")
            }
        }
        
        return true
    }
}
```

### 2. Track Events

```swift
// Track a simple event
await DatalyrSDK.shared.track("button_clicked")

// Track an event with properties
await DatalyrSDK.shared.track("purchase", eventData: [
    "product_id": "abc123",
    "amount": 29.99,
    "currency": "USD"
])
```

### 3. Track Screen Views

```swift
// Track a screen view
await DatalyrSDK.shared.screen("home_screen")

// Track with additional properties
await DatalyrSDK.shared.screen("product_detail", properties: [
    "product_id": "abc123",
    "category": "electronics"
])
```

### 4. Identify Users

```swift
// Identify a user
await DatalyrSDK.shared.identify("user123", properties: [
    "email": "user@example.com",
    "plan": "premium"
])
```

## SKAdNetwork Integration

The Datalyr iOS SDK includes automatic SKAdNetwork conversion value encoding, making it easy to compete with enterprise Mobile Measurement Partners (MMPs) like AppsFlyer and Adjust at a fraction of the cost.

### Quick Setup

```swift
import DatalyrSDK

// Initialize with SKAdNetwork support
try await DatalyrSDK.configureWithSKAdNetwork(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY",
    template: "ecommerce", // or "gaming" or "subscription"
    debug: true
)
```

### Industry Templates

Choose the template that best fits your app:

#### E-commerce Template
Optimized for online stores and retail apps:
```swift
// Track purchase with automatic revenue encoding
await DatalyrSDK.trackPurchase(value: 29.99, currency: "USD", productId: "shirt_001")

// Track funnel events
await DatalyrSDK.trackWithSKAdNetwork("view_item", eventData: ["product_id": "shirt_001"])
await DatalyrSDK.trackWithSKAdNetwork("add_to_cart", eventData: ["product_id": "shirt_001"])
await DatalyrSDK.trackWithSKAdNetwork("begin_checkout", eventData: ["cart_value": 89.97])
```

#### Gaming Template
Optimized for mobile games:
```swift
// Track game events with automatic encoding
await DatalyrSDK.trackWithSKAdNetwork("tutorial_complete", eventData: ["level": 1])
await DatalyrSDK.trackWithSKAdNetwork("level_complete", eventData: ["level": 5, "score": 1250])
await DatalyrSDK.trackWithSKAdNetwork("achievement_unlocked", eventData: ["achievement": "first_win"])

// Track in-app purchases
await DatalyrSDK.trackPurchase(value: 4.99, currency: "USD", productId: "extra_lives")
```

#### Subscription Template
Optimized for subscription-based apps:
```swift
// Track subscription events
await DatalyrSDK.trackWithSKAdNetwork("trial_start", eventData: ["plan": "premium"])
await DatalyrSDK.trackSubscription(value: 9.99, currency: "USD", plan: "monthly")
await DatalyrSDK.trackWithSKAdNetwork("upgrade", eventData: [
    "revenue": 19.99,
    "from_plan": "basic",
    "to_plan": "premium"
])
```

### Revenue Encoding

The SDK automatically encodes revenue into 8 tiers for optimal SKAdNetwork attribution:

| Revenue Range | Tier | Bit Encoding |
|---------------|------|--------------|
| $0 - $1 | 0 | `000` |
| $1 - $5 | 1 | `001` |
| $5 - $10 | 2 | `010` |
| $10 - $25 | 3 | `011` |
| $25 - $50 | 4 | `100` |
| $50 - $100 | 5 | `101` |
| $100 - $250 | 6 | `110` |
| $250+ | 7 | `111` |

### Testing Conversion Values

Test your SKAdNetwork implementation without sending to Apple:

```swift
// Test conversion values locally
let purchaseValue = DatalyrSDK.getConversionValue(for: "purchase", properties: ["revenue": 29.99])
print("Purchase conversion value: \(purchaseValue ?? 0)")

let cartValue = DatalyrSDK.getConversionValue(for: "add_to_cart", properties: nil)
print("Add to cart conversion value: \(cartValue ?? 0)")
```

### Global Convenience Functions

Use simple global functions for common SKAdNetwork events:

```swift
// Simple purchase tracking
await datalyrTrackPurchase(value: 49.99, productId: "premium_upgrade")

// Simple subscription tracking
await datalyrTrackSubscription(value: 12.99, plan: "pro_monthly")

// Track any event with SKAdNetwork encoding
await datalyrTrackWithSKAdNetwork("signup", properties: ["source": "homepage"])

// Test conversion values
let testValue = datalyrGetConversionValue(for: "purchase", properties: ["revenue": 25.00])
```

### Requirements for SKAdNetwork

- iOS 14.0+ (automatically handled - falls back gracefully on older versions)
- SKAdNetwork framework (automatically included)
- Proper App Store Connect configuration for SKAdNetwork

### Benefits vs. Enterprise MMPs

✅ **Same Attribution Functionality** as AppsFlyer/Adjust  
✅ **90% Cost Savings** compared to enterprise MMPs  
✅ **Automatic Revenue Optimization** with 8-tier encoding  
✅ **Industry-Specific Templates** for maximum performance  
✅ **Unified Analytics** - web + mobile in one dashboard  
✅ **No Setup Complexity** - works out of the box

## Configuration

### Basic Configuration

```swift
let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY"
)
```

### Advanced Configuration

```swift
let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY",
    debug: true,                    // Enable debug logging
    maxRetries: 3,                  // Number of retry attempts
    timeout: 30.0,                  // Request timeout in seconds
    batchSize: 20,                  // Events per batch
    flushInterval: 15.0,            // Auto-flush interval in seconds
    maxQueueSize: 1000,             // Maximum events in queue
    enableAutoEvents: true,         // Enable automatic events
    enableAttribution: true         // Enable attribution tracking
)
```

## Auto Events

Enable automatic tracking of common events:

```swift
let autoConfig = AutoEventConfig(
    trackSessions: true,        // Track app sessions
    trackScreenViews: true,     // Track screen changes
    trackAppUpdates: true,      // Track app version changes
    trackPerformance: false     // Track performance metrics
)

let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY",
    enableAutoEvents: true,
    autoEventConfig: autoConfig
)
```

## SwiftUI Integration

### Automatic Screen Tracking

```swift
import SwiftUI
import DatalyrSDK

struct ContentView: View {
    var body: some View {
        NavigationView {
            VStack {
                Text("Hello, World!")
            }
            .navigationTitle("Home")
        }
        .onAppear {
            Task {
                await DatalyrSDK.shared.screen("home_screen")
            }
        }
    }
}
```

### Event Tracking in Views

```swift
struct ProductView: View {
    let product: Product
    
    var body: some View {
        VStack {
            Text(product.name)
            
            Button("Add to Cart") {
                Task {
                    await DatalyrSDK.shared.track("add_to_cart", eventData: [
                        "product_id": product.id,
                        "price": product.price
                    ])
                }
            }
        }
    }
}
```

## UIKit Integration

### Automatic Screen Tracking

```swift
import UIKit
import DatalyrSDK

class HomeViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        Task {
            await DatalyrSDK.shared.screen("home_screen")
        }
    }
}
```

## Attribution Tracking

The SDK automatically captures attribution data from deep links and campaign parameters:

### Supported Parameters

- **UTM Parameters**: `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`
- **Platform Click IDs**: `fbclid`, `ttclid`, `gclid`, `twclid`
- **Custom Parameters**: Any additional parameters in deep links

### Deep Link Setup

```swift
// In your SceneDelegate or AppDelegate
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    
    // Datalyr SDK automatically processes attribution parameters
    // No additional code needed - attribution data is captured automatically
}
```

## Privacy & GDPR Compliance

The Datalyr iOS SDK is designed with privacy in mind:

- **No IDFA Required** - Works without advertising identifiers
- **Local Storage** - Sensitive data stored securely in Keychain
- **Opt-out Support** - Respect user privacy preferences
- **Minimal Data Collection** - Only collects necessary analytics data

### Privacy Configuration

```swift
let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY",
    respectDoNotTrack: true  // Respect DNT settings
)
```

## Error Handling

The SDK provides comprehensive error handling:

```swift
do {
    try await DatalyrSDK.shared.initialize(config: config)
} catch DatalyrError.invalidConfiguration(let message) {
    print("Configuration error: \(message)")
} catch DatalyrError.networkError(let error) {
    print("Network error: \(error)")
} catch {
    print("Unexpected error: \(error)")
}
```

## Testing

### Debug Mode

Enable debug mode to see detailed logs:

```swift
let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY",
    debug: true
)
```

### Manual Flush

Force immediate sending of events:

```swift
await DatalyrSDK.shared.flush()
```

### SDK Status

Check SDK status and queue information:

```swift
let status = DatalyrSDK.shared.getStatus()
print("Queue size: \(status.queueStats.queueSize)")
print("Is processing: \(status.queueStats.isProcessing)")
```

## API Reference

### Core Methods

| Method | Description |
|--------|-------------|
| `initialize(config:)` | Initialize the SDK with configuration |
| `track(_:eventData:)` | Track a custom event |
| `screen(_:properties:)` | Track a screen view |
| `identify(_:properties:)` | Identify a user |
| `alias(_:previousId:)` | Create user alias |
| `reset()` | Reset user session |
| `flush()` | Manually flush events |
| `getStatus()` | Get SDK status |

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `workspaceId` | String | Required | Your Datalyr workspace ID |
| `apiKey` | String | Required | Your Datalyr API key |
| `debug` | Bool | `false` | Enable debug logging |
| `maxRetries` | Int | `3` | Maximum retry attempts |
| `timeout` | TimeInterval | `15.0` | Request timeout |
| `batchSize` | Int | `10` | Events per batch |
| `flushInterval` | TimeInterval | `10.0` | Auto-flush interval |
| `maxQueueSize` | Int | `100` | Maximum queue size |

## Requirements

- iOS 13.0+
- macOS 10.15+
- tvOS 13.0+
- watchOS 6.0+
- Swift 5.5+
- Xcode 13.0+

## Support

- **Documentation**: [docs.datalyr.com](https://docs.datalyr.com)
- **Issues**: [GitHub Issues](https://github.com/datalyr/datalyr-ios-sdk/issues)
- **Email**: support@datalyr.com

## License

This SDK is available under the MIT License. See the LICENSE file for more info.

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

---

Built with ❤️ by the Datalyr team 