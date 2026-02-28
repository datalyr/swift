# @datalyr/swift

Official Datalyr SDK for iOS. Server-side attribution tracking, analytics, and ad platform integrations.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Event Tracking](#event-tracking)
  - [Custom Events](#custom-events)
  - [Screen Views](#screen-views)
  - [E-Commerce Events](#e-commerce-events)
- [User Identity](#user-identity)
  - [Anonymous ID](#anonymous-id)
  - [Identifying Users](#identifying-users)
- [Attribution](#attribution)
- [Platform Integrations](#platform-integrations)
  - [Meta](#meta-facebook)
  - [TikTok](#tiktok)
  - [Apple Search Ads](#apple-search-ads)
- [SKAdNetwork](#skadnetwork)
- [App Tracking Transparency](#app-tracking-transparency)
- [Offline Support](#offline-support)
- [SwiftUI and UIKit](#swiftui-and-uikit)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Installation

### Swift Package Manager (Recommended)

1. In Xcode, select File > Add Package Dependencies
2. Enter the repository URL:
   ```
   https://github.com/datalyr/swift
   ```
3. Select version 1.3.0 or later
4. Add DatalyrSDK to your target

### CocoaPods

Add to your Podfile:

```ruby
pod 'DatalyrSDK', '~> 1.3.0'
```

Then run:

```bash
pod install
```

---

## Quick Start

```swift
import DatalyrSDK

// Initialize
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    enableAttribution: true
)
try await DatalyrSDK.shared.initialize(config: config)

// Track events
await DatalyrSDK.shared.track("button_clicked", eventData: [
    "button": "signup"
])

// Identify users
await DatalyrSDK.shared.identify("user_123", properties: [
    "email": "user@example.com"
])

// Track purchases
await DatalyrSDK.shared.trackPurchase(value: 99.99, currency: "USD", productId: "product_123")
```

---

## Configuration

```swift
let config = DatalyrConfig(
    // Required
    apiKey: "dk_your_api_key",

    // Features
    debug: false,                          // Console logging
    enableAutoEvents: true,                // Track app lifecycle
    enableAttribution: true,               // Capture attribution data

    // Event Queue
    batchSize: 10,                         // Events per batch
    flushInterval: 10.0,                   // Send interval seconds
    maxQueueSize: 100,                     // Max queued events

    // iOS
    skadTemplate: "ecommerce",             // SKAdNetwork template

    // Meta SDK
    metaAppId: "1234567890",
    metaClientToken: "abc123",
    enableMetaAttribution: true,
    forwardEventsToMeta: true,

    // TikTok SDK
    tiktokAppId: "7123456789",             // TikTok App ID
    tiktokEventsAppId: "your_events_id",   // Events API App ID
    enableTikTokAttribution: true,
    forwardEventsToTikTok: true
)
```

---

## Event Tracking

### Custom Events

```swift
// Simple event
await DatalyrSDK.shared.track("signup_started")

// Event with properties
await DatalyrSDK.shared.track("product_viewed", eventData: [
    "product_id": "SKU123",
    "product_name": "Blue Shirt",
    "price": 29.99,
    "currency": "USD"
])
```

### Screen Views

```swift
await DatalyrSDK.shared.screen("Home")

await DatalyrSDK.shared.screen("Product Details", properties: [
    "product_id": "SKU123"
])
```

### E-Commerce Events

Standard e-commerce events that also forward to Meta and TikTok:

```swift
// View product
await DatalyrSDK.shared.trackViewContent(
    contentId: "SKU123",
    contentName: "Blue Shirt",
    contentType: "product",
    value: 29.99,
    currency: "USD"
)

// Add to cart
await DatalyrSDK.shared.trackAddToCart(
    value: 29.99,
    currency: "USD",
    productId: "SKU123",
    productName: "Blue Shirt"
)

// Start checkout
await DatalyrSDK.shared.trackInitiateCheckout(
    value: 59.98,
    currency: "USD",
    numItems: 2,
    productIds: ["SKU123", "SKU456"]
)

// Complete purchase
await DatalyrSDK.shared.trackPurchase(
    value: 59.98,
    currency: "USD",
    productId: "order_123"
)

// Subscription
await DatalyrSDK.shared.trackSubscription(
    value: 9.99,
    currency: "USD",
    plan: "monthly_pro"
)

// Registration
await DatalyrSDK.shared.trackCompleteRegistration(method: "email")

// Search
await DatalyrSDK.shared.trackSearch(query: "blue shoes", resultIds: ["SKU1", "SKU2"])

// Lead
await DatalyrSDK.shared.trackLead(value: 100.0, currency: "USD")

// Payment info
await DatalyrSDK.shared.trackAddPaymentInfo(success: true)
```

---

## User Identity

### Anonymous ID

Every device gets a persistent anonymous ID on first launch:

```swift
let anonymousId = DatalyrSDK.shared.getAnonymousId()
// "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
```

This ID:
- Persists across app sessions
- Links events before and after user identification
- Can be passed to your backend for server-side attribution

### Identifying Users

Link the anonymous ID to a known user:

```swift
await DatalyrSDK.shared.identify("user_123", properties: [
    "email": "user@example.com",
    "name": "John Doe",
    "phone": "+1234567890"
])
```

After `identify()`:
- All future events include `user_id`
- Historical anonymous events can be linked server-side
- User data is forwarded to Meta/TikTok for Advanced Matching

### Logout

Clear user data on logout:

```swift
await DatalyrSDK.shared.reset()
```

---

## Attribution

### Automatic Capture

The SDK captures attribution from deep links and referrers:

```swift
let attribution = DatalyrSDK.shared.getAttributionData()
```

Captured parameters:

| Type | Parameters |
|------|------------|
| UTM | `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term` |
| Click IDs | `fbclid`, `gclid`, `ttclid`, `twclid`, `li_click_id`, `msclkid` |
| Campaign | `campaign_id`, `adset_id`, `ad_id` |

### Deferred Deep Links

Capture attribution from App Store installs:

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    enableAttribution: true,
    metaAppId: "1234567890",
    enableMetaAttribution: true
)

try await DatalyrSDK.shared.initialize(config: config)

// Check for deferred attribution
if let deferred = DatalyrSDK.shared.getDeferredAttributionData() {
    print(deferred.fbclid ?? "none")      // Facebook click ID
    print(deferred.campaignId ?? "none")  // Campaign ID
}
```

---

## Platform Integrations

Bundled Meta and TikTok SDKs. No extra dependencies needed.

### Meta (Facebook)

Add to Info.plist:

```xml
<key>FacebookAppID</key>
<string>YOUR_FACEBOOK_APP_ID</string>
<key>FacebookClientToken</key>
<string>YOUR_CLIENT_TOKEN</string>
<key>FacebookDisplayName</key>
<string>Your App Name</string>
```

Initialize:

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    metaAppId: "1234567890",
    metaClientToken: "abc123",
    enableMetaAttribution: true,
    forwardEventsToMeta: true
)
```

### TikTok

Add to Info.plist:

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>tiktok</string>
  <string>snssdk1180</string>
  <string>snssdk1233</string>
</array>
```

Initialize:

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    tiktokAppId: "7123456789",              // TikTok App ID (Developer Portal)
    tiktokEventsAppId: "your_events_id",    // Events API App ID (Events Manager)
    tiktokAccessToken: "your_access_token", // Events API Access Token
    enableTikTokAttribution: true,
    forwardEventsToTikTok: true
)
```

**Where to find your TikTok credentials:**

| Credential | Where to get it |
|------------|----------------|
| `tiktokAppId` | [TikTok Developer Portal](https://developers.tiktok.com) → Your App → App ID |
| `tiktokEventsAppId` | TikTok Business Center → Assets → Events → Your App → App ID |
| `tiktokAccessToken` | TikTok Business Center → Assets → Events → Your App → Settings → Access Token |

> **Note:** The `tiktokAccessToken` enables client-side TikTok SDK features (enhanced attribution matching, real-time event forwarding). Without it, events are still tracked server-side via Datalyr postbacks — you'll see a warning in debug mode.
```

### Apple Search Ads

Attribution for users who install from Apple Search Ads (iOS 14.3+). Automatically fetched on initialization.

```swift
// Check if user came from Apple Search Ads
if let asaAttribution = DatalyrSDK.shared.getAppleSearchAdsAttribution() {
    if asaAttribution.attribution {
        print(asaAttribution.campaignId ?? 0)    // Campaign ID
        print(asaAttribution.campaignName ?? "") // Campaign name
        print(asaAttribution.adGroupId ?? 0)     // Ad group ID
        print(asaAttribution.keyword ?? "")      // Search keyword
        print(asaAttribution.clickDate ?? "")    // Click date
    }
}
```

Attribution data is automatically included in all events with the `asa_` prefix:
- `asa_campaign_id`, `asa_campaign_name`
- `asa_adgroup_id`, `asa_adgroup_name`
- `asa_keyword_id`, `asa_keyword`
- `asa_org_id`, `asa_org_name`
- `asa_click_date`, `asa_conversion_type`

No additional configuration needed. The SDK uses Apple's AdServices API.

### Check Integration Status

```swift
let status = DatalyrSDK.shared.getPlatformIntegrationStatus()
// ["meta": true, "tiktok": true, "appleSearchAds": true]
```

---

## SKAdNetwork

iOS 14+ conversion tracking with automatic value management:

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    skadTemplate: "ecommerce"
)

try await DatalyrSDK.shared.initialize(config: config)

// E-commerce events update conversion values
await DatalyrSDK.shared.trackPurchase(value: 99.99, currency: "USD")
```

| Template | Events |
|----------|--------|
| `ecommerce` | purchase, add_to_cart, begin_checkout, signup, subscribe, view_item |
| `gaming` | level_complete, tutorial_complete, purchase, achievement_unlocked |
| `subscription` | trial_start, subscribe, upgrade, cancel, signup |

---

## App Tracking Transparency

Update platform SDKs after ATT dialog:

### Built-in ATT Request (Recommended)

```swift
if #available(iOS 14.5, *) {
    let status = await DatalyrSDK.shared.requestTrackingAuthorization()
    // 0=notDetermined, 1=restricted, 2=denied, 3=authorized
}
```

### Manual ATT Handling

```swift
import AppTrackingTransparency

ATTrackingManager.requestTrackingAuthorization { status in
    Task {
        await DatalyrSDK.shared.updateTrackingAuthorization(status: status.rawValue)
    }
}
```

### Check ATT Status

```swift
let isAuthorized = DatalyrSDK.shared.isTrackingAuthorized()
let status = DatalyrSDK.shared.getTrackingAuthorizationStatus()
```

---

## Offline Support

Events are batched for efficiency and stored when offline.

### Manual Flush

```swift
await DatalyrSDK.shared.flush()
```

### Queue Status

```swift
let status = DatalyrSDK.shared.getStatus()
print(status.queueStats.queueSize)  // Events waiting
print(status.queueStats.isOnline)   // Network available
```

---

## SwiftUI and UIKit

### SwiftUI

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
        }
    }
}
```

### UIKit

```swift
import UIKit
import DatalyrSDK

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Task {
            let config = DatalyrConfig(apiKey: "dk_your_api_key")
            try? await DatalyrSDK.shared.initialize(config: config)
        }
        return true
    }
}
```

---

## Auto Events

Enable automatic lifecycle tracking:

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    enableAutoEvents: true
)
```

| Event | Trigger |
|-------|---------|
| `app_install` | First app open |
| `app_open` | App launch |
| `app_background` | App enters background |
| `app_foreground` | App returns to foreground |
| `app_update` | App version changes |
| `session_start` | New session begins |
| `session_end` | Session expires (30 min inactivity) |

---

## Troubleshooting

### Events not appearing

1. Check API key starts with `dk_`
2. Enable `debug: true`
3. Check `DatalyrSDK.shared.getStatus()` for queue info
4. Verify network connectivity
5. Call `flush()` to force send

### Build errors

```bash
# Clean build folder
Cmd+Shift+K in Xcode

# Reset package caches
File > Packages > Reset Package Caches

# Update packages
File > Packages > Update to Latest Package Versions
```

### Meta not working

Verify Info.plist contains required keys (see [Meta setup](#meta-facebook)). Check status with `DatalyrSDK.shared.getPlatformIntegrationStatus()`.

### TikTok not working

1. Make sure you have all three TikTok credentials (see [TikTok setup](#tiktok))
2. The `tiktokAccessToken` is required for client-side SDK — without it, you'll see a warning in debug mode but server-side tracking still works
3. Verify Info.plist contains `LSApplicationQueriesSchemes`
4. Check status: `DatalyrSDK.shared.getPlatformIntegrationStatus()`

---

## License

MIT
