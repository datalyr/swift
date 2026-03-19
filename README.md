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
  - [Automatic Capture](#automatic-capture)
  - [Web-to-App Attribution](#web-to-app-attribution)
- [Platform Integrations](#platform-integrations)
  - [Meta (Facebook)](#meta-facebook)
  - [TikTok](#tiktok)
  - [Google Ads](#google-ads)
  - [Apple Search Ads](#apple-search-ads)
- [SKAdNetwork](#skadnetwork)
- [App Tracking Transparency](#app-tracking-transparency)
- [Auto Events](#auto-events)
- [Offline Support](#offline-support)
- [Third-Party Integrations](#third-party-integrations)
  - [Superwall](#superwall)
  - [RevenueCat](#revenuecat)
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
    skadTemplate: "ecommerce"              // SKAdNetwork template
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

Standard e-commerce events:

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
- User data is sent server-side for ad platform matching via postbacks

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

### Web-to-App Attribution

Automatically recover attribution from a web prelander when users install the app from an ad.

**How it works:**

On first install, the SDK calls the Datalyr API to match the device's IP against recent `$app_download_click` web events (fired by the web SDK's `trackAppDownloadClick()`) within 24 hours — ~90%+ accuracy for immediate installs.

No additional mobile code is needed. Attribution is recovered automatically during `initialize()` on first install, before the `app_install` event fires.

After a match, the SDK:
1. Merges web attribution (click IDs, UTMs, cookies) into the mobile session
2. Tracks a `$web_attribution_matched` event for analytics
3. All subsequent events (including purchases) carry the matched attribution

**Fallback:** If IP matching misses (e.g., VPN toggle during install), email-based attribution is still recovered when `identify()` is called with the user's email.

---

## Platform Integrations

Conversion events are routed to ad platforms server-side via the Datalyr postback system. No client-side ad SDKs (Facebook SDK, TikTok SDK, etc.) are needed in your app. The SDK captures click IDs and attribution data from ad URLs, then the backend handles hashing, formatting, and sending conversions to each platform's API.

### Meta (Facebook)

Conversions are sent to Meta via the [Conversions API (CAPI)](https://developers.facebook.com/docs/marketing-api/conversions-api/).

**What the SDK does:** Captures `fbclid` from ad click URLs, collects IDFA (when ATT authorized), and sends user data (email, phone) with events.

**What the backend does:** Hashes PII (SHA-256), formats the CAPI payload, and sends conversions with the `fbclid` and `_fbc`/`_fbp` cookies for matching.

**Setup:**
1. Connect your Meta ad account in the Datalyr dashboard (Settings > Connections)
2. Select your Meta Pixel
3. Create postback rules to map events (e.g., `purchase` → `Purchase`, `lead` → `Lead`)

No Facebook SDK, no `Info.plist` changes, no `FacebookAppID` needed in your app.

### TikTok

Conversions are sent to TikTok via the [Events API](https://business-api.tiktok.com/portal/docs?id=1741601162187777).

**What the SDK does:** Captures `ttclid` from ad click URLs and collects device identifiers (IDFA/GAID).

**What the backend does:** Hashes user data, formats the Events API payload, and sends conversions with the `ttclid` and `_ttp` cookie for matching.

**Setup:**
1. Connect your TikTok Ads account in the Datalyr dashboard (Settings > Connections)
2. Select your TikTok Pixel
3. Create postback rules to map events (e.g., `purchase` → `CompletePayment`, `add_to_cart` → `AddToCart`)

No TikTok SDK, no `LSApplicationQueriesSchemes`, no access tokens needed in your app.

### Google Ads

Conversions are sent to Google via the [Google Ads API](https://developers.google.com/google-ads/api/docs/conversions/overview).

**What the SDK does:** Captures `gclid`, `gbraid`, and `wbraid` from ad click URLs. Collects user data for enhanced conversions.

**What the backend does:** Hashes user data, maps events to Google conversion actions, and sends conversions with click IDs for attribution.

**Setup:**
1. Connect your Google Ads account in the Datalyr dashboard (Settings > Connections)
2. Select your conversion actions
3. Create postback rules to map events (e.g., `purchase` → your Google conversion action)

No Google SDK needed in your app beyond the Play Install Referrer (already included).

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
// ["appleSearchAds": true]
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

## Third-Party Integrations

### Superwall

Pass Datalyr attribution data to Superwall to personalize paywalls by ad source, campaign, ad set, and keyword.

```swift
// After both SDKs are initialized
Superwall.shared.setUserAttributes(DatalyrSDK.shared.getSuperwallAttributes())

// Your placements will now have attribution data available as filters
Superwall.shared.register(placement: "onboarding_paywall")
```

Call after `DatalyrSDK.shared.initialize()` completes. If using ATT on iOS, call again after the user responds to the ATT prompt to include the IDFA.

### RevenueCat

Pass Datalyr attribution data to RevenueCat for revenue attribution and offering targeting.

```swift
// After both SDKs are configured
Purchases.shared.attribution.setAttributes(DatalyrSDK.shared.getRevenueCatAttributes())
```

Call after configuring the Purchases SDK and before the first purchase. If using ATT, call again after permission is granted to include IDFA. The AdSupport framework is required for IDFA collection.

> Datalyr also receives Superwall and RevenueCat events via server-side webhooks for analytics. The SDK methods and webhook integration are independent — you can use one or both.

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

---

## License

MIT
