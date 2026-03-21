# @datalyr/swift

Official Datalyr SDK for iOS. Server-side attribution tracking, analytics, SKAdNetwork conversion management, and third-party integrations.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Event Tracking](#event-tracking)
- [User Identity](#user-identity)
- [Attribution](#attribution)
- [SKAdNetwork](#skadnetwork)
- [Apple Search Ads](#apple-search-ads)
- [App Tracking Transparency](#app-tracking-transparency)
- [Third-Party Integrations](#third-party-integrations)
- [Web-to-App Attribution](#web-to-app-attribution)
- [SwiftUI Integration](#swiftui-integration)
- [UIKit Integration](#uikit-integration)
- [Global Convenience Functions](#global-convenience-functions)
- [Deep Link Handling](#deep-link-handling)
- [Delegate Protocol](#delegate-protocol)
- [Auto Events](#auto-events)
- [Offline Support](#offline-support)
- [Exported Types](#exported-types)
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
3. Select version 2.1.2 or later
4. Add DatalyrSDK to your target

### CocoaPods

Add to your Podfile:

```ruby
pod 'DatalyrSDK', '~> 2.1.2'
```

Then run:

```bash
pod install
```

**Platform support:** iOS 13.0+, macOS 10.15+, tvOS 13.0+, watchOS 6.0+. Swift 5.7+.

---

## Quick Start

```swift
import DatalyrSDK

// Initialize with basic config
try await DatalyrSDK.configure(apiKey: "dk_your_api_key")

// Or initialize with full config
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    enableAttribution: true,
    enableAutoEvents: true
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

### DatalyrConfig

All configuration properties with their defaults:

```swift
let config = DatalyrConfig(
    // Required
    apiKey: "dk_your_api_key",

    // Optional — backward compatibility
    workspaceId: "",

    // Server tracking
    useServerTracking: true,               // Use server-side API

    // Debug
    debug: false,                          // Console logging

    // API
    endpoint: "https://ingest.datalyr.com/track",   // API endpoint
    maxRetries: 3,                         // Max retry attempts
    retryDelay: 1.0,                       // Retry delay (seconds)
    timeout: 15.0,                         // Request timeout (seconds)

    // Event Queue
    batchSize: 10,                         // Events per batch
    flushInterval: 10.0,                   // Auto-flush interval (seconds)
    maxQueueSize: 100,                     // Max queued events

    // Privacy
    respectDoNotTrack: true,               // Honor Do Not Track

    // Features
    enableAutoEvents: true,                // Automatic lifecycle tracking
    enableAttribution: true,               // Attribution capture

    // Auto Events
    autoEventConfig: AutoEventConfig(
        trackSessions: true,               // Session start/end
        trackScreenViews: true,            // Enable screen view events via screen()
        trackAppUpdates: true,             // App version changes
        trackPerformance: false,           // Performance metrics
        sessionTimeoutMs: 1_800_000,       // 30 minutes
        autoTrackScreenViews: false        // Auto-swizzle UIViewController (UIKit only)
    ),

    // SKAdNetwork
    skadTemplate: "ecommerce"              // Conversion template
)
```

### Static Configure Methods

Convenience methods for common configurations:

```swift
// Basic
try await DatalyrSDK.configure(apiKey: "dk_your_api_key")

// With options
try await DatalyrSDK.configure(
    apiKey: "dk_your_api_key",
    workspaceId: "ws_123",
    debug: true,
    enableAutoEvents: true,
    enableAttribution: true
)

// With SKAdNetwork
try await DatalyrSDK.configureWithSKAdNetwork(
    apiKey: "dk_your_api_key",
    template: "ecommerce",
    debug: false,
    enableAutoEvents: true,
    enableAttribution: true
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

Each `screen()` call fires a single `pageview` event with the `screen` property set. Session data (`session_id`, `pageviews_in_session`, `previous_screen`) is automatically attached when auto-events are enabled.

### E-Commerce Events

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

### Revenue Tracking

> **Important:** If you use **Superwall** or **RevenueCat**, do not use `trackPurchase()`, `trackSubscription()`, or `trackRevenue()` for revenue attribution. These fire client-side before payment is confirmed, so trials and failed payments get counted as revenue. Use the [Superwall](https://docs.datalyr.com/integrations/superwall) or [RevenueCat](https://docs.datalyr.com/integrations/revenuecat) webhook integration for revenue events instead — they only fire when real money changes hands. Use the SDK for behavioral events only (`track("paywall_view")`, `track("trial_start")`, `screen()`, `identify()`, etc.).

Generic revenue event with a custom name:

```swift
await DatalyrSDK.shared.trackRevenue("custom_revenue_event", properties: [
    "value": 49.99,
    "currency": "USD",
    "source": "in_app"
])
```

### App Update Tracking

```swift
await DatalyrSDK.shared.trackAppUpdate(
    previousVersion: "2.0.1",
    currentVersion: "2.1.2"
)
```

---

## User Identity

### Anonymous ID

Every device gets a persistent anonymous ID on first launch:

```swift
let anonymousId = DatalyrSDK.shared.getAnonymousId()
// "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
```

This ID persists across app sessions and links events before and after user identification.

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
- If `email` is in properties (or the userId is an email), web attribution is automatically fetched and merged

### Alias

Link two user identifiers:

```swift
await DatalyrSDK.shared.alias("new_user_id", previousId: "old_user_id")

// Without previousId, uses current userId or visitorId
await DatalyrSDK.shared.alias("new_user_id")
```

### Reset

Clear user data on logout:

```swift
await DatalyrSDK.shared.reset()
```

Clears `userId`, user properties, visitor ID, session ID, and attribution data. The `anonymousId` persists.

---

## Attribution

### Get Attribution Data

```swift
let attribution = DatalyrSDK.shared.getAttributionData()
```

Returns an `AttributionData` struct with these fields:

| Category | Fields |
|----------|--------|
| Install | `installTime`, `firstOpenTime` |
| Datalyr LYR | `lyr`, `datalyr`, `dlTag`, `dlCampaign` |
| UTM | `utmSource`, `utmMedium`, `utmCampaign`, `utmTerm`, `utmContent`, `utmId`, `utmSourcePlatform`, `utmCreativeFormat`, `utmMarketingTactic` |
| Click IDs | `fbclid`, `ttclid`, `gclid`, `wbraid`, `gbraid`, `twclid`, `liClickId`, `msclkid` |
| Partner | `partnerId`, `affiliateId`, `referrerId`, `sourceId` |
| Campaign | `campaignId`, `adId`, `adsetId`, `creativeId`, `placementId`, `keyword`, `matchtype`, `network`, `device` |
| Standard | `campaignSource`, `campaignMedium`, `campaignName`, `campaignTerm`, `campaignContent` |
| Other | `referrer`, `deepLinkUrl`, `installReferrer`, `attributionTimestamp` |

### Set Attribution Data

Manually set attribution:

```swift
var data = AttributionData()
data.utmSource = "custom_source"
data.utmCampaign = "summer_sale"
await DatalyrSDK.shared.setAttributionData(data)
```

### Journey Tracking

Multi-touch attribution with first-touch, last-touch, and full touchpoint history:

```swift
// First-touch/last-touch and touchpoint count as a dictionary
let journeyData = DatalyrSDK.shared.getJourneyData()

// Structured summary
let summary = DatalyrSDK.shared.getJourneySummary()
// summary.hasFirstTouch, summary.hasLastTouch
// summary.touchpointCount, summary.daysSinceFirstTouch
// summary.sources  — e.g. ["facebook", "google"]

// Full touchpoint history
let touchpoints = DatalyrSDK.shared.getJourney()
for tp in touchpoints {
    print(tp.source, tp.medium, tp.campaign, tp.sessionId)
}
```

### Deferred Attribution

```swift
let deferred = DatalyrSDK.shared.getDeferredAttributionData()
// Returns nil — deferred deep linking is handled via prelanders and IP matching
```

---

## SKAdNetwork

iOS 14+ conversion tracking with automatic value management. Supports SKAN 3.0 (iOS 14.0+) and SKAN 4.0 (iOS 16.1+).

### Initialize with SKAdNetwork

```swift
// Via static method
try await DatalyrSDK.initializeWithSKAdNetwork(
    config: DatalyrConfig(apiKey: "dk_your_api_key"),
    template: "ecommerce"
)

// Or via convenience method
try await DatalyrSDK.configureWithSKAdNetwork(
    apiKey: "dk_your_api_key",
    template: "ecommerce"
)

// Or via DatalyrConfig directly
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    skadTemplate: "ecommerce"
)
try await DatalyrSDK.shared.initialize(config: config)
```

### Track with SKAdNetwork

Events tracked via `trackWithSKAdNetwork` automatically update conversion values:

```swift
await DatalyrSDK.shared.trackWithSKAdNetwork("level_complete", eventData: [
    "level": 5
])

// E-commerce methods (trackPurchase, trackSubscription, trackAddToCart,
// trackInitiateCheckout, trackCompleteRegistration, trackLead) automatically
// use SKAdNetwork encoding when a template is configured.
await DatalyrSDK.shared.trackPurchase(value: 99.99, currency: "USD")
```

### Conversion Templates

| Template | Events |
|----------|--------|
| `ecommerce` | purchase, add_to_cart, begin_checkout, signup, subscribe, view_item |
| `gaming` | level_complete, tutorial_complete, purchase, achievement_unlocked |
| `subscription` | trial_start, subscribe, upgrade, cancel, signup |

### Get Conversion Value

Test what conversion value an event would produce:

```swift
let value = DatalyrSDK.shared.getConversionValue(for: "purchase", properties: [
    "revenue": 49.99
])
// Returns 0-63 or nil if encoder not initialized
```

---

## Apple Search Ads

Attribution for users who install from Apple Search Ads (iOS 14.3+). Fetched automatically on initialization via the AdServices framework.

```swift
if let asa = DatalyrSDK.shared.getAppleSearchAdsAttribution() {
    if asa.attribution {
        print(asa.orgId)            // Organization ID
        print(asa.orgName)          // Organization name
        print(asa.campaignId)       // Campaign ID
        print(asa.campaignName)     // Campaign name
        print(asa.adGroupId)        // Ad group ID
        print(asa.adGroupName)      // Ad group name
        print(asa.keyword)          // Search keyword
        print(asa.keywordId)        // Keyword ID
        print(asa.clickDate)        // Click date
        print(asa.conversionType)   // Conversion type
        print(asa.region)           // Region
    }
}
```

`AppleSearchAdsAttribution` fields:

| Field | Type | Description |
|-------|------|-------------|
| `attribution` | `Bool` | Whether the install is attributed to Search Ads |
| `orgId` | `Int?` | Organization ID |
| `orgName` | `String?` | Organization name |
| `campaignId` | `Int?` | Campaign ID |
| `campaignName` | `String?` | Campaign name |
| `adGroupId` | `Int?` | Ad group ID |
| `adGroupName` | `String?` | Ad group name |
| `conversionType` | `String?` | Conversion type (e.g., "Download", "Redownload") |
| `clickDate` | `String?` | Date of the ad click |
| `keyword` | `String?` | Search keyword that triggered the ad |
| `keywordId` | `Int?` | Keyword ID |
| `region` | `String?` | Region/country code |

Attribution data is automatically included in all events with the `asa_` prefix (e.g., `asa_campaign_id`, `asa_org_name`).

### Check Integration Status

```swift
let status = DatalyrSDK.shared.getPlatformIntegrationStatus()
// ["appleSearchAds": true]
```

---

## App Tracking Transparency

### Built-in ATT Request

```swift
#if os(iOS)
if #available(iOS 14.5, *) {
    let status = await DatalyrSDK.shared.requestTrackingAuthorization()
    // 0 = notDetermined, 1 = restricted, 2 = denied, 3 = authorized

    // Also available as a static method
    let status2 = await DatalyrSDK.requestTrackingAuthorization()
}
#endif
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
// 0 = notDetermined, 1 = restricted, 2 = denied, 3 = authorized
```

### IDFA

```swift
// Instance method
let idfa = DatalyrSDK.shared.getIDFA()  // String? — nil if not authorized

// Static method
let idfa2 = DatalyrSDK.getIDFA()
```

### Advertiser Data

Returns a dictionary with `idfa` (if authorized), `att_status`, and `tracking_authorized`:

```swift
let data = DatalyrSDK.shared.getAdvertiserData()
// or
let data2 = DatalyrSDK.getAdvertiserData()
```

---

## Third-Party Integrations

### Superwall

Pass Datalyr attribution data to Superwall to personalize paywalls by ad source, campaign, and keyword.

```swift
Superwall.shared.setUserAttributes(DatalyrSDK.shared.getSuperwallAttributes())
```

Call after `DatalyrSDK.shared.initialize()` completes. If using ATT, call again after the user responds to the ATT prompt to include IDFA.

**Returned keys:**

| Key | Description |
|-----|-------------|
| `datalyr_id` | The user's DATALYR visitor ID |
| `media_source` | Traffic source (e.g., `facebook`, `google`) |
| `campaign` | Campaign name from the ad |
| `adgroup` | Ad group or ad set name |
| `ad` | Individual ad ID |
| `keyword` | Search keyword that triggered the ad |
| `network` | Ad network name |
| `utm_source` | UTM source parameter |
| `utm_medium` | UTM medium parameter (e.g., `cpc`) |
| `utm_campaign` | UTM campaign parameter |
| `utm_term` | UTM term parameter |
| `utm_content` | UTM content parameter |
| `lyr` | DATALYR tracking link ID |
| `fbclid` | Meta click ID from the ad URL |
| `gclid` | Google click ID from the ad URL |
| `ttclid` | TikTok click ID from the ad URL |
| `idfa` | Apple advertising ID (only if ATT authorized) |
| `att_status` | App Tracking Transparency status (`0`-`3`) |

### RevenueCat

Pass Datalyr attribution data to RevenueCat for revenue attribution and offering targeting.

```swift
Purchases.shared.attribution.setAttributes(DatalyrSDK.shared.getRevenueCatAttributes())
```

Call after configuring the Purchases SDK and before the first purchase. If using ATT, call again after permission is granted.

**Returned keys:**

| Key | Description |
|-----|-------------|
| `$datalyrId` | The user's DATALYR visitor ID |
| `$mediaSource` | Traffic source (e.g., `facebook`, `google`) |
| `$campaign` | Campaign name from the ad |
| `$adGroup` | Ad group or ad set name |
| `$ad` | Individual ad ID |
| `$keyword` | Search keyword that triggered the ad |
| `$idfa` | Apple advertising ID (only if ATT authorized) |
| `$attConsentStatus` | ATT consent status (e.g., `authorized`, `denied`) |
| `utm_source` | UTM source parameter |
| `utm_medium` | UTM medium parameter (e.g., `cpc`) |
| `utm_campaign` | UTM campaign parameter |
| `utm_term` | UTM term parameter |
| `utm_content` | UTM content parameter |
| `lyr` | DATALYR tracking link ID |
| `fbclid` | Meta click ID from the ad URL |
| `gclid` | Google click ID from the ad URL |
| `ttclid` | TikTok click ID from the ad URL |
| `wbraid` | Google web-to-app click ID |
| `gbraid` | Google app click ID |
| `network` | Ad network name |
| `creative_id` | Ad creative ID |

---

## Web-to-App Attribution

Automatically recover attribution from a web prelander when users install the app from an ad.

**How it works:**

On first install, the SDK calls the Datalyr API to match the device's IP against recent `$app_download_click` web events (fired by the web SDK's `trackAppDownloadClick()`) within 24 hours.

No additional mobile code is needed. Attribution is recovered automatically during `initialize()` on first install, before the `app_install` event fires.

After a match, the SDK:
1. Merges web attribution (click IDs, UTMs, cookies) into the mobile session
2. Tracks a `$web_attribution_matched` event
3. All subsequent events carry the matched attribution

**Fallback:** If IP matching misses (e.g., VPN toggle during install), email-based attribution is recovered when `identify()` is called with the user's email.

---

## SwiftUI Integration

### View Modifiers

Track screen views and events declaratively with SwiftUI view modifiers:

```swift
import SwiftUI
import DatalyrSDK

struct ProductView: View {
    var body: some View {
        VStack {
            Text("Product Details")
        }
        .datalyrScreen("Product Details", properties: [
            "product_id": "SKU123"
        ])
    }
}

struct CheckoutView: View {
    var body: some View {
        Button("Place Order") { /* ... */ }
            .datalyrTrack("checkout_viewed", properties: [
                "cart_value": 59.98
            ])
    }
}
```

`View.datalyrScreen(_:properties:)` tracks a screen view when the view appears. `View.datalyrTrack(_:properties:)` tracks a custom event when the view appears.

### App Initialization

```swift
@main
struct MyApp: App {
    init() {
        Task {
            try? await DatalyrSDK.configure(apiKey: "dk_your_api_key")
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

## UIKit Integration

### View Controller Extensions

```swift
class ProductViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Track screen view (uses class name as screen name)
        datalyrTrackScreenView()

        // Track custom event
        datalyrTrack("product_viewed", properties: [
            "product_id": "SKU123"
        ])
    }
}
```

`UIViewController.datalyrTrackScreenView()` tracks a `pageview` event using the view controller's class name. Override it to customize screen names. `UIViewController.datalyrTrack(_:properties:)` tracks a custom event.

### Automatic Screen Tracking

Enable automatic screen tracking for UIKit apps by swizzling `viewDidAppear` on all view controllers. System view controllers (`UINavigationController`, `UITabBarController`, `UIAlertController`, etc.) are automatically filtered out. Screen names are cleaned up (`MyProfileViewController` → `MyProfile`).

**Option 1: Enable via config** (recommended):

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    autoEventConfig: AutoEventConfig(autoTrackScreenViews: true)
)
try await DatalyrSDK.shared.initialize(config: config)
```

**Option 2: Enable manually** after initialization:

```swift
DatalyrSDK.enableAutomaticScreenTracking()
```

**Exclude specific screens:**

```swift
// Set before enabling automatic tracking
DatalyrSDK.excludedScreenClasses = ["OnboardingContainerVC", "DebugMenuVC"]
```

> **SwiftUI apps:** Automatic UIViewController swizzling does not capture SwiftUI views (`UIHostingController` is filtered). Use the `.datalyrScreen()` view modifier on your SwiftUI views instead:
>
> ```swift
> struct HomeView: View {
>     var body: some View {
>         Text("Home")
>             .datalyrScreen("Home")
>     }
> }
> ```

### App Delegate Initialization

```swift
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Task {
            let config = DatalyrConfig(
                apiKey: "dk_your_api_key",
                autoEventConfig: AutoEventConfig(autoTrackScreenViews: true)
            )
            try? await DatalyrSDK.shared.initialize(config: config)
        }
        return true
    }
}
```

---

## Global Convenience Functions

Free functions that call through to `DatalyrSDK.shared`:

| Function | Equivalent |
|----------|-----------|
| `datalyrTrack(_:properties:)` | `DatalyrSDK.shared.track(_:eventData:)` |
| `datalyrScreen(_:properties:)` | `DatalyrSDK.shared.screen(_:properties:)` |
| `datalyrIdentify(_:properties:)` | `DatalyrSDK.shared.identify(_:properties:)` |
| `datalyrAlias(_:previousId:)` | `DatalyrSDK.shared.alias(_:previousId:)` |
| `datalyrReset()` | `DatalyrSDK.shared.reset()` |
| `datalyrFlush()` | `DatalyrSDK.shared.flush()` |
| `datalyrGetAnonymousId()` | `DatalyrSDK.shared.getAnonymousId()` |
| `datalyrTrackWithSKAdNetwork(_:properties:)` | `DatalyrSDK.shared.trackWithSKAdNetwork(_:eventData:)` |
| `datalyrTrackPurchase(value:currency:productId:)` | `DatalyrSDK.shared.trackPurchase(value:currency:productId:)` |
| `datalyrTrackSubscription(value:currency:plan:)` | `DatalyrSDK.shared.trackSubscription(value:currency:plan:)` |
| `datalyrGetConversionValue(for:properties:)` | `DatalyrSDK.shared.getConversionValue(for:properties:)` |

All async functions require `await`:

```swift
await datalyrTrack("event_name", properties: ["key": "value"])
await datalyrScreen("Home")
await datalyrIdentify("user_123")
await datalyrAlias("new_id", previousId: "old_id")
await datalyrReset()
await datalyrFlush()
await datalyrTrackPurchase(value: 9.99, currency: "USD", productId: "sku_1")
await datalyrTrackSubscription(value: 4.99, currency: "USD", plan: "monthly")
await datalyrTrackWithSKAdNetwork("level_complete", properties: ["level": 5])

let anonId = datalyrGetAnonymousId()
let cv = datalyrGetConversionValue(for: "purchase", properties: ["revenue": 49.99])
```

---

## Deep Link Handling

Handle deep links for attribution tracking from `AppDelegate` or `SceneDelegate`:

```swift
// AppDelegate
func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
) -> Bool {
    Task {
        await DatalyrSDK.shared.handleDeepLink(url)
    }
    return true
}

// SceneDelegate
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let url = URLContexts.first?.url {
        Task {
            await DatalyrSDK.shared.handleDeepLink(url)
        }
    }
}

// SwiftUI
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Task {
                        await DatalyrSDK.shared.handleDeepLink(url)
                    }
                }
        }
    }
}
```

---

## Delegate Protocol

Implement `DatalyrSDKDelegate` to receive SDK callbacks. All methods are optional (default empty implementations are provided).

```swift
class AppCoordinator: DatalyrSDKDelegate {
    init() {
        DatalyrSDK.shared.delegate = self
    }

    func datalyrDidInitialize() {
        // SDK is fully initialized
    }

    func datalyrDidReceiveAttribution(_ attribution: AttributionData) {
        // Attribution data received
    }

    func datalyrDidUpdateConversionValue(fineValue: Int, coarseValue: String?) {
        // SKAdNetwork/AdAttributionKit conversion value updated
        // fineValue: 0-63
        // coarseValue: "low", "medium", or "high" (SKAN 4.0+), nil for SKAN 3.0
    }

    func datalyrDidFailToSendEvent(_ error: DatalyrPlatformError, eventName: String?) {
        // A platform integration failed
        switch error {
        case .skadnetworkUpdateFailed(let underlyingError):
            print("SKAN error: \(underlyingError?.localizedDescription ?? "")")
        case .attributionFetchFailed(let platform, let underlyingError):
            print("\(platform) attribution error: \(underlyingError?.localizedDescription ?? "")")
        case .networkError(let underlyingError):
            print("Network error: \(underlyingError.localizedDescription)")
        case .configurationError(let message):
            print("Config error: \(message)")
        }
    }
}
```

### Error Types

`DatalyrPlatformError` cases:

| Case | Description |
|------|-------------|
| `.skadnetworkUpdateFailed(underlyingError:)` | SKAdNetwork conversion value update failed |
| `.attributionFetchFailed(platform:underlyingError:)` | Attribution fetch from a platform failed |
| `.networkError(underlyingError:)` | Network request failed |
| `.configurationError(message:)` | SDK configuration error |

---

## Auto Events

Enable automatic lifecycle tracking:

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    enableAutoEvents: true,
    autoEventConfig: AutoEventConfig(
        trackSessions: true,
        trackScreenViews: true,
        trackAppUpdates: true,
        trackPerformance: false,
        sessionTimeoutMs: 1_800_000,  // 30 minutes
        autoTrackScreenViews: true    // Auto-track UIKit screens via swizzle
    )
)
```

| Event | Trigger |
|-------|---------|
| `app_install` | First app open (includes attribution data) |
| `session_start` | New session begins |
| `session_end` | 30 min inactivity timeout or app terminated |
| `pageview` | Screen view (via `screen()` method) |

---

## Offline Support

Events are batched and stored locally when offline. They are sent when connectivity returns.

### Manual Flush

```swift
await DatalyrSDK.shared.flush()
```

### Queue Status

```swift
let status = DatalyrSDK.shared.getStatus()
print(status.queueStats.queueSize)       // Events waiting
print(status.queueStats.isProcessing)    // Currently sending
print(status.queueStats.isOnline)        // Network available
print(status.queueStats.oldestEventAge)  // Age of oldest event (TimeInterval?)
```

### Initialization Check

```swift
let ready = DatalyrSDK.shared.isInitialized  // Bool
let error = DatalyrSDK.shared.getLastError() // Error?
```

---

## Exported Types

Public types available after importing `DatalyrSDK`:

| Type | Description |
|------|-------------|
| `DatalyrSDK` | Main SDK class (singleton via `.shared`) |
| `DatalyrConfig` | SDK configuration |
| `AutoEventConfig` | Auto event tracking configuration |
| `AttributionData` | Attribution tracking data (UTM, click IDs, campaign details) |
| `AppleSearchAdsAttribution` | Apple Search Ads attribution fields |
| `DeferredDeepLinkResult` | Deferred deep link result |
| `EventPayload` | Complete event payload |
| `FingerprintData` | Device fingerprint data |
| `DeviceInfo` | Device information |
| `SDKStatus` | SDK status with queue stats and attribution |
| `QueueStats` | Event queue statistics |
| `SessionData` | Session tracking data |
| `QueuedEvent` | Queued event for offline storage |
| `HTTPResponse` | HTTP response wrapper |
| `AnyCodable` | Codable wrapper for `Any` values |
| `TouchAttribution` | Attribution data for a touchpoint |
| `TouchPoint` | Single touchpoint in the customer journey |
| `JourneySummary` | Journey tracking summary |
| `DatalyrSDKDelegate` | Delegate protocol for SDK callbacks |
| `DatalyrPlatformError` | Platform integration error enum |
| `DatalyrError` | SDK error enum |
| `EventData` | Typealias for `[String: Any]` |
| `UserProperties` | Typealias for `[String: Any]` |

---

## Troubleshooting

### Events not appearing

1. Check API key starts with `dk_`
2. Enable `debug: true` in config
3. Check `DatalyrSDK.shared.getStatus()` for queue info
4. Verify `DatalyrSDK.shared.isInitialized` is `true`
5. Check network connectivity via `getStatus().queueStats.isOnline`
6. Call `flush()` to force send

### SKAdNetwork conversion values not updating

1. Verify `skadTemplate` is set in config or use `initializeWithSKAdNetwork(config:template:)`
2. Check `getConversionValue(for:properties:)` returns a non-nil value
3. Conversion values only update on iOS 14.0+
4. Set the delegate and implement `datalyrDidUpdateConversionValue` to monitor updates

### Attribution data missing

1. Verify `enableAttribution: true` in config
2. For Apple Search Ads: requires iOS 14.3+ and the AdServices framework
3. For web-to-app: the prelander must fire `trackAppDownloadClick()` with the web SDK
4. Check `getPlatformIntegrationStatus()` for integration availability

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
