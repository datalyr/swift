# 🍎 Datalyr iOS SDK

[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%2013%2B-blue.svg)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/swift-5.7%2B-orange.svg)](https://swift.org)

**Complete attribution tracking + automatic events for iOS**

*The only iOS SDK that combines Mixpanel-style automatic events with deep attribution tracking*

---

## ✨ Features

- 🚀 **Modern Swift**: Built with Swift 5.7+ and async/await
- 🎯 **Complete Attribution**: Deep link tracking with UTM parameters and click IDs
- 📊 **Auto Events**: Automatic sessions, screen views, and app lifecycle tracking
- 🔄 **Offline Support**: Event queueing with retry logic and persistence
- 🔒 **Privacy First**: GDPR compliant with Keychain storage for sensitive data
- 📱 **iOS 13+**: Compatible with iOS 13 and later
- 🍃 **Lightweight**: Minimal dependencies and footprint
- 📦 **Easy Integration**: Swift Package Manager + CocoaPods support

---

## 🚀 Quick Start

### 1. Installation

#### Swift Package Manager (Recommended)

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/datalyr/datalyr-ios-sdk.git", from: "1.0.0")
]
```

Or add through Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/datalyr/datalyr-ios-sdk.git`
3. Follow the prompts

#### CocoaPods

```ruby
pod 'DatalyrSDK', '~> 1.0'
```

### 2. Initialize the SDK

```swift
import DatalyrSDK

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        Task {
            try await DatalyrSDK.configure(
                workspaceId: "your_workspace_id",
                apiKey: "dk_your_api_key",
                debug: true,
                enableAutoEvents: true,
                enableAttribution: true
            )
        }
        
        return true
    }
}
```

### 3. Track Events

```swift
// Track simple events
await datalyrTrack("button_clicked")

// Track with properties
await datalyrTrack("purchase_completed", properties: [
    "product_id": "abc123",
    "amount": 29.99,
    "currency": "USD"
])

// Identify users
await datalyrIdentify("user123", properties: [
    "email": "user@example.com",
    "name": "John Doe",
    "plan": "premium"
])

// Track screen views
await datalyrScreen("Home Screen")
```

---

## 🎯 Automatic Events (Zero Code Required)

The SDK automatically tracks these events when `enableAutoEvents: true`:

- **`session_start`** - User starts new session with attribution data
- **`session_end`** - Session ends with duration and event count
- **`screen_view`** - User navigates between screens (with SwiftUI/UIKit integration)
- **`app_install`** - First app launch with full attribution
- **`app_update`** - App version changes
- **`app_foregrounded`** - App becomes active
- **`app_backgrounded`** - App goes to background
- **`app_launch_performance`** - App startup timing

---

## 📱 SwiftUI Integration

```swift
import SwiftUI
import DatalyrSDK

struct ProductView: View {
    var body: some View {
        VStack {
            Text("Product Details")
            
            Button("Purchase") {
                Task {
                    await datalyrTrack("purchase_button_clicked", properties: [
                        "product_id": "123"
                    ])
                }
            }
        }
        .datalyrScreen("Product Details", properties: [
            "product_id": "123"
        ])
    }
}
```

## 📱 UIKit Integration

```swift
import UIKit
import DatalyrSDK

class ProductViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Manual screen tracking
        Task {
            await datalyrScreen("Product Details", properties: [
                "product_id": "123"
            ])
        }
    }
    
    @IBAction func purchaseButtonTapped(_ sender: UIButton) {
        Task {
            await datalyrTrack("purchase_button_clicked", properties: [
                "product_id": "123"
            ])
        }
    }
}

// Enable automatic screen tracking for all view controllers
DatalyrSDK.enableAutomaticScreenTracking()
```

---

## 🎯 Attribution Tracking

### Deep Link Setup

```swift
// In AppDelegate
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    Task {
        await DatalyrSDK.shared.handleDeepLink(url)
    }
    return true
}

// In SceneDelegate (iOS 13+)
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    Task {
        await DatalyrSDK.shared.handleDeepLink(url)
    }
}
```

### Supported Attribution Parameters

Automatically tracks these parameters from deep links:

- **Datalyr**: `lyr`, `datalyr`, `dl_tag`, `dl_campaign`
- **UTM**: `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`
- **Facebook**: `fbclid`, `fb_click_id`
- **Google**: `gclid`, `wbraid`, `gbraid`
- **TikTok**: `ttclid`, `tt_click_id`
- **Twitter**: `twclid`
- **LinkedIn**: `li_click_id`
- **Microsoft**: `msclkid`

---

## ⚙️ Advanced Configuration

```swift
let config = DatalyrConfig(
    workspaceId: "your_workspace_id",
    apiKey: "dk_your_api_key",
    debug: false,
    endpoint: "https://datalyr-ingest.datalyr-ingest.workers.dev",
    maxRetries: 3,
    retryDelay: 1.0,
    timeout: 15.0,
    batchSize: 10,
    flushInterval: 30.0,
    maxQueueSize: 100,
    respectDoNotTrack: true,
    enableAutoEvents: true,
    enableAttribution: true,
    autoEventConfig: AutoEventConfig(
        trackSessions: true,
        trackScreenViews: true,
        trackAppUpdates: true,
        trackPerformance: false,
        sessionTimeoutMs: 1800000 // 30 minutes
    )
)

try await DatalyrSDK.shared.initialize(config: config)
```

---

## 🔒 Privacy & GDPR Compliance

### Data Collection

The SDK collects:
- Event data you explicitly track
- Device information (model, OS version, screen size)
- App information (version, build number)
- Session data (start time, duration)
- Attribution data (when available)
- IDFA (with proper iOS 14+ permission handling)

### Privacy Controls

```swift
// Respect Do Not Track setting
let config = DatalyrConfig(
    workspaceId: "your_workspace_id",
    apiKey: "your_api_key",
    respectDoNotTrack: true
)

// Reset user data (GDPR right to be forgotten)
await datalyrReset()
```

### Secure Data Storage

- **UserDefaults**: Non-sensitive data and preferences
- **Keychain**: Sensitive data (API keys, user IDs, device IDs)
- **No iCloud**: Data never syncs between devices
- **Local Only**: No data shared between apps

---

## 📊 API Reference

### Core Methods

```swift
// Initialize SDK
try await DatalyrSDK.configure(workspaceId: String, apiKey: String)
try await DatalyrSDK.shared.initialize(config: DatalyrConfig)

// Track Events
await datalyrTrack(eventName: String, properties: [String: Any]?)
await DatalyrSDK.shared.track(eventName: String, eventData: [String: Any]?)

// Track Screen Views
await datalyrScreen(screenName: String, properties: [String: Any]?)
await DatalyrSDK.shared.screen(screenName: String, properties: [String: Any]?)

// User Management
await datalyrIdentify(userId: String, properties: [String: Any]?)
await datalyrAlias(newUserId: String, previousId: String?)
await datalyrReset()

// Utility
await datalyrFlush()
let status = DatalyrSDK.shared.getStatus()
let attribution = DatalyrSDK.shared.getAttributionData()
```

### SwiftUI View Modifiers

```swift
.datalyrScreen("Screen Name", properties: ["key": "value"])
.datalyrTrack("Event Name", properties: ["key": "value"])
```

---

## 🧪 Example App

Check out the complete example app in `/examples/BasicExample.swift`:

```swift
import SwiftUI
import DatalyrSDK

@main
struct ExampleApp: App {
    init() {
        Task {
            try await DatalyrSDK.configure(
                workspaceId: "your_workspace_id",
                apiKey: "dk_your_api_key",
                debug: true,
                enableAutoEvents: true,
                enableAttribution: true
            )
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

---

## 🔧 Debugging

### Enable Debug Mode

```swift
try await DatalyrSDK.configure(
    workspaceId: "your_workspace_id",
    apiKey: "your_api_key",
    debug: true
)
```

### Check SDK Status

```swift
let status = DatalyrSDK.shared.getStatus()
print("Initialized: \(status.initialized)")
print("Queue size: \(status.queueStats.queueSize)")
print("Visitor ID: \(status.visitorId)")
```

---

## 🚀 Migration from React Native SDK

The iOS SDK provides similar functionality:

```swift
// React Native
datalyr.track('event_name', { key: 'value' })
datalyr.identify('user_123', { email: 'user@example.com' })

// iOS
await datalyrTrack("event_name", properties: ["key": "value"])
await datalyrIdentify("user_123", properties: ["email": "user@example.com"])
```

---

## ⚡ Performance

- **Memory usage**: < 5MB typical
- **Network**: Batched requests with offline queueing
- **CPU**: Minimal impact with background processing
- **Battery**: Optimized for minimal battery drain
- **Build time**: No impact on compile time

---

## 🛠️ Troubleshooting

### Common Issues

1. **Events not appearing**: Enable debug mode and check network connectivity
2. **Attribution not working**: Verify deep link handling in AppDelegate/SceneDelegate
3. **Build errors**: Ensure iOS 13+ deployment target
4. **IDFA not working**: Check App Tracking Transparency permission

### Getting Help

- 📧 **Email**: support@datalyr.com
- 📖 **Documentation**: https://docs.datalyr.com
- 🐛 **Issues**: GitHub Issues
- 💬 **Discord**: https://discord.gg/datalyr

---

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

**🔥 The only iOS SDK that combines attribution tracking with automatic events like Mixpanel!** 

*Production-ready with complete feature parity to our React Native SDK.* 