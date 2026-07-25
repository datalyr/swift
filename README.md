# DatalyrSDK

Server-side attribution, event tracking, SKAdNetwork conversion values, and Apple Search Ads attribution for iOS.

Current release: **2.1.10**. Every event posts to `https://ingest.datalyr.com/track`.

Full reference: [docs.datalyr.com/sdk-reference/ios](https://docs.datalyr.com/sdk-reference/ios).

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Event Tracking](#event-tracking)
- [User Identity](#user-identity)
- [Attribution](#attribution)
- [SKAdNetwork](#skadnetwork)
- [Apple Search Ads](#apple-search-ads)
- [App Tracking Transparency](#app-tracking-transparency)
- [Superwall and RevenueCat](#superwall-and-revenuecat)
- [Web-to-App Attribution](#web-to-app-attribution)
- [SwiftUI](#swiftui)
- [UIKit](#uikit)
- [Global Convenience Functions](#global-convenience-functions)
- [Deep Links](#deep-links)
- [Delegate Protocol](#delegate-protocol)
- [Queue and Limits](#queue-and-limits)
- [Exported Types](#exported-types)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Requirements

| Item | Value |
|---|---|
| Minimum iOS | 13.0 |
| Swift tools version | 5.7 |
| Current release | 2.1.10 |
| Frameworks linked | `Foundation`, `UIKit`, `StoreKit`, `AdServices` (weak) |

---

## Installation

### Swift Package Manager

1. In Xcode, open **File > Add Package Dependencies**.
2. Enter `https://github.com/datalyr/swift`.
3. Select version 2.1.10.
4. Add the `DatalyrSDK` product to your app target.

In `Package.swift`:

```swift
.package(url: "https://github.com/datalyr/swift", from: "2.1.10")
```

### CocoaPods

> **The CocoaPods podspec does not ship `PrivacyInfo.xcprivacy`.** App Store review requires a privacy manifest. Add your own manifest, or install with Swift Package Manager, which does ship one.

```ruby
pod 'DatalyrSDK', '~> 2.1.10'
```

Run `pod install`. Open the generated `.xcworkspace`.

---

## Quick Start

```swift
import DatalyrSDK

// Minimal
try await DatalyrSDK.configure(apiKey: "dk_your_api_key")

// Or with a full config object
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    enableAutoEvents: true,
    enableAttribution: true
)
try await DatalyrSDK.shared.initialize(config: config)

await DatalyrSDK.shared.track("signup_completed", eventData: [
    "plan": "pro",
    "seats": 5
])

await DatalyrSDK.shared.identify("user_123", properties: [
    "email": "person@example.com"
])

await DatalyrSDK.shared.trackPurchase(
    value: 99.99,
    currency: "USD",
    productId: "pro_yearly"
)
```

`initialize(config:)` throws `DatalyrError.invalidApiKey` on an empty key. The SDK buffers 50 events, 50 identity calls, and 50 deep links sent before initialization finishes.

### Static configure methods

```swift
try await DatalyrSDK.configure(apiKey: "dk_your_api_key")

try await DatalyrSDK.configure(
    apiKey: "dk_your_api_key",
    workspaceId: "ws_123",
    debug: true,
    enableAutoEvents: true,
    enableAttribution: true
)

try await DatalyrSDK.configureWithSKAdNetwork(
    apiKey: "dk_your_api_key",
    workspaceId: "",
    template: "ecommerce",
    debug: false,
    enableAutoEvents: true,
    enableAttribution: true
)
```

---

## Configuration

> **`retryDelay`, `timeout`, and `flushInterval` are seconds on iOS.** The React Native SDK uses milliseconds for the same three names. Copying `timeout: 15000` from a React Native configuration produces a 15,000-second timeout.

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    debug: false,
    timeout: 15.0,
    batchSize: 10,
    flushInterval: 10.0,
    maxQueueSize: 1000
)
try await DatalyrSDK.shared.initialize(config: config)
```

### DatalyrConfig

| Option | Type | Default | Unit |
|---|---|---|---|
| `apiKey` | `String` | Required. Throws when empty. | — |
| `workspaceId` | `String` | `""` | — |
| `useServerTracking` | `Bool` | `true` | — |
| `debug` | `Bool` | `false` | — |
| `endpoint` | `String` | `"https://ingest.datalyr.com/track"` | URL |
| `maxRetries` | `Int` | `3` | attempts |
| `retryDelay` | `TimeInterval` | `1.0` | **seconds** |
| `timeout` | `TimeInterval` | `15.0` | **seconds** |
| `batchSize` | `Int` | `10` | events per queue drain |
| `flushInterval` | `TimeInterval` | `10.0` | **seconds** |
| `maxQueueSize` | `Int` | `1000` | events |
| `enableAutoEvents` | `Bool` | `true` | — |
| `enableAttribution` | `Bool` | `true` | — |
| `autoEventConfig` | `AutoEventConfig?` | `nil` | — |
| `skadTemplate` | `String?` | `nil` | `gaming`, `subscription`, or ecommerce |

`skadTemplate` accepts any string. Anything other than `gaming` or `subscription` becomes the ecommerce template, with no warning.

### AutoEventConfig

> **`sessionTimeoutMs` is milliseconds, while the three interval options above are seconds.** `sessionTimeoutMs` changes only when `session_end` fires. The `session_id` on the wire rotates on a hardcoded 30 minutes that no option changes.

| Option | Type | Default | Unit |
|---|---|---|---|
| `trackSessions` | `Bool` | `true` | — |
| `trackScreenViews` | `Bool` | `true` | — |
| `autoTrackScreenViews` | `Bool` | `false` | — |
| `sessionTimeoutMs` | `TimeInterval` | `1800000` | **milliseconds** — 30 minutes |

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    autoEventConfig: AutoEventConfig(
        trackSessions: true,
        trackScreenViews: true,
        sessionTimeoutMs: 1_800_000,
        autoTrackScreenViews: true
    )
)
```

`trackScreenViews: false` suppresses every `pageview` event that `screen()` sends.

### Options that do nothing

These properties exist on the types and are read nowhere in the SDK. Setting them has no effect.

| Option | Behavior the name suggests | Actual behavior |
|---|---|---|
| `DatalyrConfig.respectDoNotTrack` | Honors Do Not Track | No Do Not Track logic exists |
| `AutoEventConfig.trackAppUpdates` | Sends `app_update` automatically | Nothing auto-sends `app_update`. Call `trackAppUpdate(previousVersion:currentVersion:)`. |
| `AutoEventConfig.trackPerformance` | Records performance metrics | No performance code exists |

### Methods that always return nil

| Method | Use instead |
|---|---|
| `getDeferredAttributionData()` | `getAppleSearchAdsAttribution()` |
| `getLastError()` | `getStatus()` |

---

## Event Tracking

### Events the SDK sends without your code

| Wire event name | Trigger |
|---|---|
| `app_install` | First `initialize()` on a device |
| `session_start` | `initialize()`, and foreground after the session ended |
| `session_end` | Inactivity timer, `willTerminateNotification`, or SDK teardown |
| `$att_status` | Every `updateTrackingAuthorization()` call |
| `$web_attribution_matched` | An email or IP lookup matched an earlier web visit |

The SDK never prompts for App Tracking Transparency on its own. It never captures the launch URL on its own — call `handleDeepLink(_:)` yourself.

### Events the SDK sends for you

These names are reserved. Never send one through `track()`.

| Method you call | Wire event name |
|---|---|
| `screen()`, `.datalyrScreen()` | `pageview` |
| `identify()` | `$identify` |
| `alias()` | `$alias` |
| `handleDeepLink()` | `$deep_link` |
| `trackAppUpdate()` | `app_update` |
| `trackPurchase()` | `purchase` |
| `trackSubscription()` | `subscribe` |
| `trackAddToCart()` | `add_to_cart` |
| `trackViewContent()` | `view_content` |
| `trackInitiateCheckout()` | `initiate_checkout` |
| `trackCompleteRegistration()` | `complete_registration` |
| `trackSearch()` | `search` |
| `trackLead()` | `lead` |
| `trackAddPaymentInfo()` | `add_payment_info` |

Event names accept `[A-Za-z0-9_-.$]` up to 100 characters. Whitespace runs collapse to `_`, so `track("Order Completed")` arrives as `Order_Completed`.

### Custom events

```swift
await DatalyrSDK.shared.track("signup_started")

await DatalyrSDK.shared.track("product_viewed", eventData: [
    "product_id": "SKU123",
    "product_name": "Blue Shirt",
    "price": 29.99,
    "currency": "USD"
])
```

### Screen views

`screen()` sends an event named `pageview`, not `screen`. Filter on `pageview` in **Events**.

```swift
await DatalyrSDK.shared.screen("Home")

await DatalyrSDK.shared.screen("Product Details", properties: [
    "product_id": "SKU123"
])
```

Each call attaches `screen`, `session_id`, `pageviews_in_session`, and `previous_screen`. Properties you pass win on a name collision.

### E-commerce events

```swift
await DatalyrSDK.shared.trackViewContent(
    contentId: "SKU123",
    contentName: "Blue Shirt",
    contentType: "product",
    value: 29.99,
    currency: "USD"
)

await DatalyrSDK.shared.trackAddToCart(
    value: 29.99,
    currency: "USD",
    productId: "SKU123",
    productName: "Blue Shirt"
)

await DatalyrSDK.shared.trackInitiateCheckout(
    value: 59.98,
    currency: "USD",
    numItems: 2,
    productIds: ["SKU123", "SKU456"]
)

await DatalyrSDK.shared.trackPurchase(
    value: 59.98,
    currency: "USD",
    productId: "order_123"
)

await DatalyrSDK.shared.trackSubscription(
    value: 9.99,
    currency: "USD",
    plan: "monthly_pro"
)

await DatalyrSDK.shared.trackCompleteRegistration(method: "email")
await DatalyrSDK.shared.trackSearch(query: "blue shoes", resultIds: ["SKU1", "SKU2"])
await DatalyrSDK.shared.trackLead(value: 100.0, currency: "USD")
await DatalyrSDK.shared.trackAddPaymentInfo(success: true)
```

`trackPurchase`, `trackSubscription`, `trackAddToCart`, `trackInitiateCheckout`, `trackCompleteRegistration`, and `trackLead` update the SKAdNetwork conversion value when `skadTemplate` is set. `trackViewContent`, `trackSearch`, and `trackAddPaymentInfo` do not.

### Revenue

> **Do not use `trackPurchase()`, `trackSubscription()`, or `trackRevenue()` for subscription revenue when you use Superwall or RevenueCat.** These fire client-side before payment is confirmed, so trials and failed payments count as revenue. Use the [Superwall](https://docs.datalyr.com/revenue/superwall) or [RevenueCat](https://docs.datalyr.com/revenue/revenuecat) webhook integration, which fires only on a confirmed charge. Use the SDK for behavioral events: `track("paywall_view")`, `screen()`, `identify()`.

```swift
await DatalyrSDK.shared.trackRevenue("custom_revenue_event", properties: [
    "value": 49.99,
    "currency": "USD",
    "source": "in_app"
])
```

### App updates

Nothing auto-sends `app_update`. Call it yourself.

```swift
await DatalyrSDK.shared.trackAppUpdate(
    previousVersion: "2.0.1",
    currentVersion: "2.1.0"
)
```

---

## User Identity

> **Calling `identify()` with a different user ID runs `reset()` first.** That rotates the anonymous ID and the visitor ID, and erases attribution, the journey, and the SKAdNetwork high-water value. Call `identify()` once per signed-in person, not on every screen.

```swift
await DatalyrSDK.shared.identify("user_123", properties: [
    "email": "person@example.com",
    "name": "John Doe",
    "phone": "+1234567890"
])
```

A repeat call with an unchanged ID and unchanged traits sends no `$identify` event. When `properties` carries an `email`, or the user ID is an email address, the SDK fetches and merges web attribution for that address.

### Identity on the wire

| Wire field | Value |
|---|---|
| `anonymousId` | Top-level. Format `anon_<UUID>`. |
| `properties.anonymous_id` | The same value, repeated. |
| `userId` | Your ID from `identify()`. The key is absent until then. |
| `properties.sessionId` | A bare UUID. No prefix. |
| `context.session_id` | The same session UUID. This is the field Datalyr reads. |
| `properties.fingerprint.deviceId` | A bare UUID for the install. |

This SDK sends no `distinct_id` and no top-level `visitor_id`. Only the Web SDK sends `distinct_id`. To pass identity to RevenueCat or Superwall, use `getRevenueCatAttributes()` or `getSuperwallAttributes()`.

### Anonymous ID

```swift
let anonymousId = DatalyrSDK.shared.getAnonymousId()
// "anon_a1b2c3d4-e5f6-7890-abcd-ef1234567890"
```

### Alias

```swift
await DatalyrSDK.shared.alias("new_user_id", previousId: "old_user_id")

// Without previousId, the SDK uses the current user ID, or the visitor ID
await DatalyrSDK.shared.alias("new_user_id")
```

`alias()` links two IDs for one person. It does not run `reset()`.

### Reset

```swift
await DatalyrSDK.shared.reset()
```

`reset()` rotates the anonymous ID, the visitor ID, and the session ID. It clears the user ID, user properties, attribution, the journey, and SKAdNetwork state. Call it on logout.

---

## Attribution

Pass every incoming link to the SDK. The SDK does not read the launch URL for you.

```swift
.onOpenURL { url in
    Task { await DatalyrSDK.shared.handleDeepLink(url) }
}
```

The SDK reads these 38 parameters from the query string and the URL fragment. Key matching is case-insensitive.

| Group | Parameters |
|---|---|
| Datalyr | `lyr`, `datalyr`, `dl_tag`, `dl_campaign` |
| Click IDs | `fbclid`, `ttclid`, `gclid`, `wbraid`, `gbraid`, `dclid`, `twclid`, `li_click_id`, `msclkid`, `oppref` |
| Click ID aliases | `tt_click_id` and `tiktok_click_id` both store as `ttclid` |
| UTM | `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `utm_id`, `utm_source_platform`, `utm_creative_format`, `utm_marketing_tactic` |
| Partner | `partner_id`, `affiliate_id`, `referrer_id`, `source_id` |
| Ad structure | `campaign_id`, `ad_id`, `adset_id`, `creative_id`, `placement_id`, `keyword`, `matchtype`, `network`, `device` |

Each `utm_*` value is mirrored to `campaign_source`, `campaign_medium`, `campaign_name`, `campaign_term`, and `campaign_content`. Since 2.1.9 the whole attribution record rides on every event. Properties you pass to `track()` win on a name collision.

### Read attribution

```swift
let attribution = DatalyrSDK.shared.getAttributionData()
```

`AttributionData` properties:

| Category | Properties |
|---|---|
| Install | `installTime`, `firstOpenTime` |
| Datalyr | `lyr`, `datalyr`, `dlTag`, `dlCampaign` |
| UTM | `utmSource`, `utmMedium`, `utmCampaign`, `utmTerm`, `utmContent`, `utmId`, `utmSourcePlatform`, `utmCreativeFormat`, `utmMarketingTactic` |
| Click IDs | `fbclid`, `ttclid`, `gclid`, `wbraid`, `gbraid`, `dclid`, `oppref`, `twclid`, `liClickId`, `msclkid` |
| Partner | `partnerId`, `affiliateId`, `referrerId`, `sourceId` |
| Ad structure | `campaignId`, `adId`, `adsetId`, `creativeId`, `placementId`, `keyword`, `matchtype`, `network`, `device` |
| Mirrored UTM | `campaignSource`, `campaignMedium`, `campaignName`, `campaignTerm`, `campaignContent` |
| Other | `referrer`, `deepLinkUrl`, `installReferrer`, `attributionTimestamp` |

### Set attribution

```swift
var data = AttributionData()
data.utmSource = "newsletter"
data.utmCampaign = "spring_sale"
await DatalyrSDK.shared.setAttributionData(data)
```

### Journey

```swift
let journeyData = DatalyrSDK.shared.getJourneyData()
let summary = DatalyrSDK.shared.getJourneySummary()
let touchpoints = DatalyrSDK.shared.getJourney()

for touchpoint in touchpoints {
    print(touchpoint.source, touchpoint.medium, touchpoint.campaign, touchpoint.sessionId)
}
```

The journey holds up to 30 touchpoints over a 90-day window. It is readable in the app only. The SDK attaches no journey field to any event.

---

## SKAdNetwork

> **Set `skadTemplate` at initialization.** Without it, `getConversionValue(for:properties:)` returns `nil` and `trackWithSKAdNetwork()` sends no conversion update.

`initialize()` registers for attribution. The framework depends on the OS version.

| iOS version | Framework used |
|---|---|
| 17.4 and later | AdAttributionKit |
| 16.1 to 17.3 | SKAdNetwork 4.0 |
| 14.0 to 16.0 | SKAdNetwork 3.0 |

```swift
try await DatalyrSDK.configureWithSKAdNetwork(
    apiKey: "dk_your_api_key",
    template: "ecommerce"
)

// Or through DatalyrConfig
let config = DatalyrConfig(apiKey: "dk_your_api_key", skadTemplate: "ecommerce")
try await DatalyrSDK.shared.initialize(config: config)

await DatalyrSDK.shared.trackWithSKAdNetwork("level_complete", eventData: [
    "level": 5
])
```

| Template | Events |
|---|---|
| `ecommerce` | purchase, add_to_cart, begin_checkout, signup, subscribe, view_item |
| `gaming` | level_complete, tutorial_complete, purchase, achievement_unlocked |
| `subscription` | trial_start, subscribe, upgrade, cancel, signup |

Conversion values only ever increase. The SDK stores a high-water fine value and sends an update only for a strictly higher fine value, or an equal fine value with a higher coarse value.

Preview a value without sending it to Apple:

```swift
let value = DatalyrSDK.shared.getConversionValue(for: "purchase", properties: [
    "revenue": 49.99
])
// 0 to 63, or nil when skadTemplate is unset
```

---

## Apple Search Ads

The SDK reads AdServices on iOS 14.3 and later, and adds these 12 properties to every event: `asa_attribution`, `asa_org_id`, `asa_org_name`, `asa_campaign_id`, `asa_campaign_name`, `asa_adgroup_id`, `asa_adgroup_name`, `asa_conversion_type`, `asa_click_date`, `asa_keyword`, `asa_keyword_id`, `asa_region`.

The fetch does not block `initialize()`, so the first events after install carry no `asa_*` values.

```swift
if let asa = DatalyrSDK.shared.getAppleSearchAdsAttribution(), asa.attribution {
    print(asa.orgId as Any, asa.orgName as Any)
    print(asa.campaignId as Any, asa.campaignName as Any)
    print(asa.adGroupId as Any, asa.adGroupName as Any)
    print(asa.keyword as Any, asa.keywordId as Any)
    print(asa.clickDate as Any, asa.conversionType as Any, asa.region as Any)
}
```

| Property | Type |
|---|---|
| `attribution` | `Bool` |
| `orgId` | `Int?` |
| `orgName` | `String?` |
| `campaignId` | `Int?` |
| `campaignName` | `String?` |
| `adGroupId` | `Int?` |
| `adGroupName` | `String?` |
| `conversionType` | `String?` — `"Download"` or `"Redownload"` |
| `clickDate` | `String?` |
| `keyword` | `String?` |
| `keywordId` | `Int?` |
| `region` | `String?` |

Check availability:

```swift
let status = DatalyrSDK.shared.getPlatformIntegrationStatus()
// ["appleSearchAds": true]
```

---

## App Tracking Transparency

The SDK caches advertiser data once at initialization. Call `updateTrackingAuthorization` after the prompt resolves, so later events carry the IDFA.

```swift
#if os(iOS)
if #available(iOS 14.5, *) {
    let status = await DatalyrSDK.shared.requestTrackingAuthorization()
    // 0 notDetermined, 1 restricted, 2 denied, 3 authorized
    print(status)
}
#endif
```

Handle the prompt yourself instead:

```swift
import AppTrackingTransparency

ATTrackingManager.requestTrackingAuthorization { status in
    Task {
        await DatalyrSDK.shared.updateTrackingAuthorization(status: status.rawValue)
    }
}
```

`updateTrackingAuthorization(status:)` takes a `UInt?`, not a `Bool`. Each call sends `$att_status` and refreshes `idfa`, `att_status`, and `advertiser_tracking_enabled` on later events.

```swift
let isAuthorized = DatalyrSDK.shared.isTrackingAuthorized()    // Bool
let status = DatalyrSDK.shared.getTrackingAuthorizationStatus() // UInt
let idfa = DatalyrSDK.shared.getIDFA()                          // String?, nil unless authorized
let advertiserData = DatalyrSDK.shared.getAdvertiserData()      // idfa, att_status, tracking_authorized
```

ATT governs the advertising identifier. It is not an analytics consent system. Your app owns consent and the App Store privacy disclosure.

---

## Superwall and RevenueCat

Call both methods after the two SDKs initialize, and again after the ATT prompt resolves.

```swift
Superwall.shared.setUserAttributes(DatalyrSDK.shared.getSuperwallAttributes())
Purchases.shared.attribution.setAttributes(DatalyrSDK.shared.getRevenueCatAttributes())
```

Both methods return `[String: String]` and omit every empty value.

### getSuperwallAttributes

| Key | Value |
|---|---|
| `datalyr_id` | The visitor ID |
| `media_source` | `utm_source` |
| `campaign` | `utm_campaign` |
| `adgroup` | `adset_id`, or `utm_content` when `adset_id` is empty |
| `ad` | `ad_id` |
| `keyword` | `keyword` |
| `network` | `network` |
| `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content` | UTM parameters |
| `lyr` | Datalyr tracking link ID |
| `fbclid`, `gclid`, `ttclid` | Ad click IDs |
| `idfa` | Apple advertising ID, only when ATT is authorized |
| `att_status` | `notDetermined`, `restricted`, `denied`, or `authorized` |

### getRevenueCatAttributes

Reserved keys:

| Key | Value |
|---|---|
| `$datalyrId` | The visitor ID |
| `$mediaSource` | `utm_source` |
| `$campaign` | `utm_campaign` |
| `$adGroup` | `adset_id` |
| `$ad` | `ad_id` |
| `$keyword` | `keyword` |
| `$idfa` | Apple advertising ID, only when ATT is authorized |
| `$attConsentStatus` | `notDetermined`, `restricted`, `denied`, or `authorized` |

Custom keys:

| Key | Value |
|---|---|
| `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content` | UTM parameters |
| `lyr` | Datalyr tracking link ID |
| `fbclid`, `gclid`, `ttclid`, `wbraid`, `gbraid` | Ad click IDs |
| `network` | Ad network |
| `creative_id` | Ad creative ID |

Neither method returns `oppref` or `gaid`.

---

## Web-to-App Attribution

On first install the SDK asks the Datalyr API to match the device IP against `$app_download_click` web events from the last 24 hours. The Web SDK fires those events through `trackAppDownloadClick()`.

The match runs inside `initialize()`, before `app_install` fires. Your app needs no extra code.

After a match the SDK merges the web click IDs, UTM parameters, and cookies into the mobile session, sends `$web_attribution_matched`, and stamps the merged attribution on every later event.

When IP matching misses — a VPN toggle during install, for example — call `identify()` with the user's email. The SDK then recovers attribution by email.

---

## SwiftUI

```swift
import SwiftUI
import DatalyrSDK

struct ProductView: View {
    var body: some View {
        VStack {
            Text("Product Details")
        }
        .datalyrScreen("Product Details", properties: ["product_id": "SKU123"])
    }
}

struct CheckoutView: View {
    var body: some View {
        Button("Place Order") {
            Task {
                await DatalyrSDK.shared.trackPurchase(
                    value: 59.98,
                    currency: "USD",
                    productId: "order_123"
                )
            }
        }
        .datalyrTrack("checkout_viewed", properties: ["cart_value": 59.98])
    }
}
```

`.datalyrScreen(_:properties:)` sends a `pageview` when the view appears. `.datalyrTrack(_:properties:)` sends your event when the view appears.

```swift
@main
struct MyApp: App {
    init() {
        Task {
            try? await DatalyrSDK.configure(apiKey: "dk_your_api_key")
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

---

## UIKit

```swift
class ProductViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        datalyrTrackScreenView()

        datalyrTrack("product_viewed", properties: ["product_id": "SKU123"])
    }
}
```

`datalyrTrackScreenView()` sends a `pageview` named after the view controller class. Override it to set your own name.

### Automatic screen tracking

Swizzling `viewDidAppear` sends a `pageview` for every view controller. The SDK filters system view controllers, including `UINavigationController`, `UITabBarController`, `UIAlertController`, and `UIHostingController`. Class names are cleaned, so `MyProfileViewController` becomes `MyProfile`.

> **Automatic swizzling never captures SwiftUI views**, because `UIHostingController` is filtered. Use `.datalyrScreen("Home")` on your SwiftUI views instead.

Enable it through the config:

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    autoEventConfig: AutoEventConfig(autoTrackScreenViews: true)
)
try await DatalyrSDK.shared.initialize(config: config)
```

Or enable it after initialization. Set `excludedScreenClasses` before you enable tracking.

```swift
DatalyrSDK.excludedScreenClasses = ["OnboardingContainerVC", "DebugMenuVC"]
DatalyrSDK.enableAutomaticScreenTracking()
```

### App delegate initialization

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

Each free function calls through to `DatalyrSDK.shared`.

| Function | Equivalent |
|---|---|
| `datalyrTrack(_:properties:)` | `track(_:eventData:)` |
| `datalyrScreen(_:properties:)` | `screen(_:properties:)` |
| `datalyrIdentify(_:properties:)` | `identify(_:properties:)` |
| `datalyrAlias(_:previousId:)` | `alias(_:previousId:)` |
| `datalyrReset()` | `reset()` |
| `datalyrFlush()` | `flush()` |
| `datalyrGetAnonymousId()` | `getAnonymousId()` |
| `datalyrTrackWithSKAdNetwork(_:properties:)` | `trackWithSKAdNetwork(_:eventData:)` |
| `datalyrTrackPurchase(value:currency:productId:)` | `trackPurchase(value:currency:productId:)` |
| `datalyrTrackSubscription(value:currency:plan:)` | `trackSubscription(value:currency:plan:)` |
| `datalyrGetConversionValue(for:properties:)` | `getConversionValue(for:properties:)` |

```swift
await datalyrTrack("event_name", properties: ["key": "value"])
await datalyrScreen("Home")
await datalyrIdentify("user_123", properties: ["email": "person@example.com"])
await datalyrAlias("new_id", previousId: "old_id")
await datalyrReset()
await datalyrFlush()
await datalyrTrackPurchase(value: 9.99, currency: "USD", productId: "sku_1")
await datalyrTrackSubscription(value: 4.99, currency: "USD", plan: "monthly")
await datalyrTrackWithSKAdNetwork("level_complete", properties: ["level": 5])

let anonymousId = datalyrGetAnonymousId()
let conversionValue = datalyrGetConversionValue(for: "purchase", properties: ["revenue": 49.99])
```

---

## Deep Links

```swift
// AppDelegate
func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
) -> Bool {
    Task { await DatalyrSDK.shared.handleDeepLink(url) }
    return true
}

// SceneDelegate
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    Task { await DatalyrSDK.shared.handleDeepLink(url) }
}

// SwiftUI
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Task { await DatalyrSDK.shared.handleDeepLink(url) }
                }
        }
    }
}
```

---

## Delegate Protocol

`DatalyrSDKDelegate` supplies default empty implementations, so implement only the callbacks you need.

```swift
class AppCoordinator: DatalyrSDKDelegate {
    init() {
        DatalyrSDK.shared.delegate = self
    }

    func datalyrDidInitialize() {}

    func datalyrDidReceiveAttribution(_ attribution: AttributionData) {}

    func datalyrDidUpdateConversionValue(fineValue: Int, coarseValue: String?) {
        // fineValue 0 to 63
        // coarseValue "low", "medium", or "high" on SKAN 4.0, nil on SKAN 3.0
    }

    func datalyrDidFailToSendEvent(_ error: DatalyrPlatformError, eventName: String?) {
        switch error {
        case .skadnetworkUpdateFailed(let underlying):
            print("SKAdNetwork: \(underlying?.localizedDescription ?? "unknown")")
        case .attributionFetchFailed(let platform, let underlying):
            print("\(platform): \(underlying?.localizedDescription ?? "unknown")")
        case .networkError(let underlying):
            print("Network: \(underlying.localizedDescription)")
        case .configurationError(let message):
            print("Config: \(message)")
        }
    }
}
```

| `DatalyrPlatformError` case | Cause |
|---|---|
| `.skadnetworkUpdateFailed(underlyingError:)` | A conversion value update failed |
| `.attributionFetchFailed(platform:underlyingError:)` | An attribution fetch failed |
| `.networkError(underlyingError:)` | A network request failed |
| `.configurationError(message:)` | The SDK configuration is invalid |

---

## Queue and Limits

> **Nothing batches over the network.** The queue drains `batchSize` events per pass, then sends one HTTP request per event. There is no batch endpoint.

| Limit | Value |
|---|---|
| Events drained per pass | 10, from `batchSize` |
| HTTP requests per drain | One per event |
| Flush interval | 10 seconds |
| Retries per event | 3 |
| Retry backoff | `min(2^n × retryDelay + random(0…1), 30)` seconds |
| `Retry-After` honored | Clamped to 0 to 30 seconds |
| Extra waits on 429 and 408 | 5, outside the retry budget |
| Request timeout | 15 seconds. Resource timeout 30 seconds. |
| Client rate limit | 100 requests per 60 seconds. The SDK waits, up to 120 seconds. |
| Queue | 1000 events |
| Dead-letter queue | 100 events |
| Pre-init buffers | 50 events, 50 identity calls, 50 deep links |
| Event data payload | 32,768 bytes of serialized JSON |
| Event name | 100 characters |
| Journey | 30 touchpoints over 90 days |
| Attribution lookup timeout | 10 seconds |

| Response | Behavior |
|---|---|
| `429`, `408` | Waits for `Retry-After`, then retries, on a separate budget of 5 waits |
| Other `4xx` | Dropped. A wrong API key produces this. |
| `5xx`, network failure | Retried with backoff up to `maxRetries`, then moved to the dead-letter queue |

Events persist across app launches and send when connectivity returns.

```swift
await DatalyrSDK.shared.flush()

let status = DatalyrSDK.shared.getStatus()
print(status.queueStats.queueSize)       // Events waiting
print(status.queueStats.isProcessing)    // Currently sending
print(status.queueStats.isOnline)        // Network available
print(status.queueStats.oldestEventAge as Any)  // TimeInterval?

let ready = DatalyrSDK.shared.isInitialized  // Bool
```

---

## Exported Types

| Type | Description |
|---|---|
| `DatalyrSDK` | The SDK class. Use `DatalyrSDK.shared`. |
| `DatalyrConfig` | SDK configuration |
| `AutoEventConfig` | Automatic event configuration |
| `AttributionData` | Attribution record |
| `AppleSearchAdsAttribution` | Apple Search Ads fields |
| `DeferredDeepLinkResult` | Return type of `getDeferredAttributionData()`, which always returns `nil` |
| `EventPayload` | The wire payload |
| `DeviceContext` | Device context |
| `DeviceInfo` | Device information |
| `SDKStatus` | Status, queue stats, and attribution |
| `QueueStats` | Queue statistics |
| `SessionData` | Session state |
| `QueuedEvent` | One queued event |
| `HTTPResponse` | HTTP response wrapper |
| `AnyCodable` | `Codable` wrapper for `Any` |
| `TouchAttribution` | Attribution for one touchpoint |
| `TouchPoint` | One touchpoint in the journey |
| `JourneySummary` | Journey summary |
| `DatalyrSDKDelegate` | Delegate protocol |
| `DatalyrPlatformError` | Platform integration errors |
| `DatalyrError` | SDK errors |
| `EventData` | `[String: Any]` |
| `UserProperties` | `[String: Any]` |

---

## Troubleshooting

### No events in the dashboard

1. Confirm the API key starts with `dk_`.
2. Confirm `DatalyrSDK.shared.isInitialized` is `true`.
3. Read `getStatus().queueStats.queueSize`. A queue that grows without draining means the API key is wrong.
4. Read `getStatus().queueStats.isOnline`.
5. Call `flush()`.
6. Open **Events** in Datalyr and filter on `app_install`.

Set `debug: true` to print `[Datalyr]` lines to the console. `getLastError()` always returns `nil`, so read `getStatus()` instead.

### Screen views are missing

Filter on `pageview`, not `screen`. `screen()` sends the event name `pageview`. Confirm `autoEventConfig.trackScreenViews` is not `false`, which suppresses every `pageview`.

### Conversion values never update

1. Confirm `skadTemplate` is set, or use `configureWithSKAdNetwork(apiKey:template:)`.
2. Confirm `getConversionValue(for:properties:)` returns a non-`nil` value.
3. Confirm the device runs iOS 14.0 or later.
4. Implement `datalyrDidUpdateConversionValue` to watch each update.

Conversion values only increase. An event that encodes a lower fine value sends nothing.

### Attribution is empty

1. Confirm `enableAttribution` is `true`.
2. Confirm your app calls `handleDeepLink(_:)` for every incoming URL.
3. For Apple Search Ads, confirm the device runs iOS 14.3 or later. Read again after a few seconds, because the fetch does not block `initialize()`.
4. For web-to-app, confirm the prelander calls `trackAppDownloadClick()` in the Web SDK.
5. Call `identify()` with the user's email as the IP-match fallback.

`getDeferredAttributionData()` always returns `nil`. Use `getAppleSearchAdsAttribution()`.

### Build errors

In Xcode:

- Clean the build folder: **Cmd+Shift+K**
- Reset package caches: **File > Packages > Reset Package Caches**
- Update packages: **File > Packages > Update to Latest Package Versions**

---

## License

MIT
