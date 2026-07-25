# Datalyr -- Complete iOS (Swift) Setup Guide

> Everything you need to set up mobile attribution, event tracking, and web-to-app campaigns in your iOS app.

Current release: **2.1.10**. Every event posts to `https://ingest.datalyr.com/track`.

**Links:** [Full Docs](https://docs.datalyr.com) | [iOS SDK Reference](https://docs.datalyr.com/sdk-reference/ios) | [GitHub](https://github.com/datalyr/swift)

---

## Step 1: Create Your Datalyr Account

1. Sign up at [datalyr.com](https://datalyr.com)
2. Open **Settings → API**
3. Copy your API key. It starts with `dk_`.

That's all you need. Only the API key is required -- `workspaceId` is no longer needed.

---

## Step 2: Install the Datalyr SDK

### Option 1: Swift Package Manager (Recommended)

1. In Xcode, select **File > Add Package Dependencies**
2. Enter the repository URL: `https://github.com/datalyr/swift`
3. Select version **2.1.10**
4. Add **DatalyrSDK** to your app target

Or in `Package.swift`:
```swift
dependencies: [
  .package(url: "https://github.com/datalyr/swift", from: "2.1.10")
]
```

### Option 2: CocoaPods

> **WARNING: The CocoaPods podspec does not ship `PrivacyInfo.xcprivacy`.** App Store review requires a privacy manifest. Add your own manifest, or install with Swift Package Manager, which does ship one.

Add to your `Podfile`:
```ruby
pod 'DatalyrSDK', '~> 2.1.10'
```

Then run:
```bash
pod install
```

### Option 3: Manual Installation

1. Download the SDK from [GitHub Releases](https://github.com/datalyr/swift/releases)
2. Drag `Sources/DatalyrSDK` folder into your Xcode project
3. Ensure "Copy items if needed" is checked

### Initialize the SDK

**SwiftUI App:**
```swift
import SwiftUI
import DatalyrSDK

@main
struct MyApp: App {
    init() {
        Task {
            let config = DatalyrConfig(
                apiKey: "dk_your_api_key",
                debug: true // Set false in production
            )

            do {
                try await DatalyrSDK.shared.initialize(config: config)
                print("Datalyr initialized successfully")
            } catch {
                print("Datalyr initialization failed: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

**UIKit App:**
```swift
import UIKit
import DatalyrSDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Task {
            let config = DatalyrConfig(
                apiKey: "dk_your_api_key",
                debug: true
            )
            try? await DatalyrSDK.shared.initialize(config: config)
        }
        return true
    }
}
```

### Full Configuration Options

> **WARNING: `retryDelay`, `timeout`, and `flushInterval` are seconds on iOS.** The React Native SDK uses milliseconds for the same three names. Copying `timeout: 15000` from a React Native configuration produces a 15,000-second timeout.

```swift
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",         // Required. Get from Settings → API

    // Debugging
    debug: false,                       // Default: false. Console logs.

    // Network
    endpoint: "https://ingest.datalyr.com/track", // Default API endpoint
    maxRetries: 3,                      // Default: 3 attempts
    retryDelay: 1.0,                    // Default: 1.0 SECONDS between retries
    timeout: 15.0,                      // Default: 15.0 SECONDS request timeout

    // Event queue
    batchSize: 10,                      // Default: 10. Events per queue drain.
    flushInterval: 10.0,                // Default: 10.0 SECONDS between flushes
    maxQueueSize: 1000,                 // Default: 1000. Max queued events offline.

    // Features
    enableAutoEvents: true,             // Default: true. Track app lifecycle events.
    enableAttribution: true,            // Default: true. Capture attribution data.

    // SKAdNetwork (iOS 14+)
    skadTemplate: "subscription"        // Options: "ecommerce", "gaming", "subscription"
)
```

The queue drains `batchSize` events per pass, then sends one HTTP request per event. There is no batch endpoint.

**Options that do nothing.** These exist on the types and are read nowhere in the SDK.

| Option | Behavior the name suggests | Actual behavior |
|---|---|---|
| `DatalyrConfig.respectDoNotTrack` | Honors Do Not Track | No Do Not Track logic exists |
| `AutoEventConfig.trackAppUpdates` | Sends `app_update` automatically | Nothing auto-sends `app_update`. Call `trackAppUpdate(previousVersion:currentVersion:)`. |
| `AutoEventConfig.trackPerformance` | Records performance metrics | No performance code exists |

`AutoEventConfig.sessionTimeoutMs` is **milliseconds** (default `1800000`), unlike the three options above. It changes only when `session_end` fires. The `session_id` on the wire rotates on a hardcoded 30 minutes that no option changes.

### What Gets Tracked Automatically

When `enableAutoEvents` is `true` (default), these events fire without any code:

| Event | Trigger |
|---|---|
| `app_install` | First app open ever (includes attribution data) |
| `session_start` | New session begins |
| `session_end` | 30 min inactivity timeout or app terminated |
| `$att_status` | Every `updateTrackingAuthorization()` call |
| `$web_attribution_matched` | An email or IP lookup matched an earlier web visit |

**Links:** [iOS SDK Docs](https://docs.datalyr.com/sdk-reference/ios) | [GitHub](https://github.com/datalyr/swift)

---

## Step 3: Track Events & Identify Users

### 3a. Custom Events

```swift
// Simple event
await DatalyrSDK.shared.track("Button Clicked")

// Event with properties
await DatalyrSDK.shared.track("Product Viewed", eventData: [
    "product_id": "SKU123",
    "product_name": "Premium Subscription",
    "price": 49.99,
    "currency": "USD",
    "category": "Subscriptions"
])
```

### 3b. Screen Views

`screen()` sends an event named `pageview`, not `screen`. Filter on `pageview` in **Events**.

```swift
// SwiftUI
.onAppear {
    Task {
        await DatalyrSDK.shared.screen("Product Details", properties: [
            "product_id": "SKU123",
            "category": "Electronics"
        ])
    }
}

// UIKit
override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Task {
        await DatalyrSDK.shared.screen("Product Details", properties: [
            "product_id": "SKU123"
        ])
    }
}
```

### 3c. E-Commerce Events

```swift
// Track a purchase
await DatalyrSDK.shared.trackPurchase(
    value: 99.99,
    currency: "USD",
    productId: "premium_subscription"
)

// Track a subscription
await DatalyrSDK.shared.trackSubscription(
    value: 9.99,
    currency: "USD",
    plan: "monthly_pro"
)

// Track revenue with SKAdNetwork encoding
await DatalyrSDK.trackWithSKAdNetwork("purchase", eventData: [
    "value": 99.99,
    "currency": "USD"
])
```

> **WARNING: If you use Superwall or RevenueCat, do NOT use `trackPurchase()`, `trackSubscription()`, or `trackRevenue()` for subscription revenue.** These fire client-side before payment is confirmed -- trials and failed payments will be counted as revenue. Use the webhook integration instead (Step 4). Only use these methods for one-time purchases when you handle billing directly.

### 3d. Identify Users

> **WARNING: Calling `identify()` with a different user ID runs `reset()` first.** That rotates the anonymous ID and the visitor ID, and erases attribution, the journey, and the SKAdNetwork high-water value. Call `identify()` once per signed-in person, not on every screen.

Call `identify()` after signup or login. **Include the user's email -- this is critical for iOS web-to-app attribution.** If IP matching fails (VPN, delayed install, network change), email is the fallback that connects the web visitor to the app user.

```swift
await DatalyrSDK.shared.identify("user_123", properties: [
    "email": "user@example.com",    // Critical for attribution
    "name": "John Doe",
    "phone": "+1234567890",
    "plan": "premium",
    "created_at": "2025-09-29"
])
```

**When to call:**
- After signup
- After login
- After profile update (if email changes)

### 3e. Alias

Associate a new user ID with a previous one (e.g., after account merge):

```swift
// Link new ID to currently identified user
await DatalyrSDK.shared.alias("new_user_456")
```

### 3f. Logout / Reset

> **WARNING: `reset()` rotates the anonymous ID and the visitor ID.** It also clears the user ID, user properties, attribution, the journey, and SKAdNetwork state, and starts a new session. The previous user's identity is unrecoverable on the device afterwards.

```swift
await DatalyrSDK.shared.reset()
```

Always call `reset()` on logout. Without it, the next user's events are attributed to the previous user.

### 3g. Anonymous ID

Every device gets a persistent anonymous ID on first launch:

```swift
let anonymousId = DatalyrSDK.shared.getAnonymousId()
// "anon_a1b2c3d4-e5f6-7890-abcd-ef1234567890"
// Pass to your backend for server-side attribution
```

The SDK sends no `distinct_id` and no top-level `visitor_id`. Only the Web SDK sends `distinct_id`.

### 3h. Sessions

The iOS SDK exposes no `getCurrentSession()` and no `endSession()`. Read session state through `getStatus()`.

```swift
let status = DatalyrSDK.shared.getStatus()
print(status.sessionId)
```

A session expires after 30 minutes of inactivity. That 30 minutes is hardcoded for the `session_id`.

**Links:** [Events Overview](https://docs.datalyr.com/understanding-data/events-overview) | [Identity Calls](https://docs.datalyr.com/understanding-data/identity-calls) | [Visitor Identification](https://docs.datalyr.com/understanding-data/visitor-identification)

---

## Step 4: Connect Your Payment Provider

> **The SDK tracks WHO your users are and WHERE they came from. Your payment provider tracks WHAT they paid. You need both for full attribution.** Revenue comes through server-side webhooks -- not the SDK.

### 4a. Superwall

**In Datalyr Dashboard:**
1. Open **Sources**
2. Click **connect** next to Superwall
3. Enter your Superwall **Project ID**
4. Copy the generated **webhook URL**

**In Superwall Dashboard:**
1. Go to **Settings > Integrations > Webhooks**
2. Click **Add Webhook Endpoint**
3. Paste the Datalyr webhook URL
4. Select **All Events**
5. Click **Save**
6. Click **Copy Secret** on the webhook endpoint (the `whsec_...` value)
7. Go back to Datalyr and paste the signing secret

**In Your Code -- Pass Attribution to Superwall:**
```swift
import DatalyrSDK
import SuperwallKit

// After BOTH SDKs are initialized
let attrs = DatalyrSDK.shared.getSuperwallAttributes()
Superwall.shared.setUserAttributes(attrs)
```

**Call this:**
- After both SDKs are initialized (on app launch)
- Again after `identify()` if user info changes
- Again after the user responds to the ATT prompt (to include IDFA)

**Returned attribute keys:**

| Key | Description |
|---|---|
| `datalyr_id` | Datalyr visitor ID |
| `media_source` | Acquisition source (from `utm_source`) |
| `campaign` | Campaign name |
| `adgroup` | Ad group / adset |
| `ad` | Ad identifier |
| `keyword` | Search keyword |
| `network` | Ad network name |
| `utm_source` | UTM source |
| `utm_medium` | UTM medium |
| `utm_campaign` | UTM campaign |
| `utm_term` | UTM term |
| `utm_content` | UTM content |
| `lyr` | Datalyr tracking link ID |
| `fbclid` | Meta click ID |
| `gclid` | Google click ID |
| `ttclid` | TikTok click ID |
| `idfa` | iOS Advertising ID (only if ATT authorized) |
| `att_status` | `notDetermined`, `restricted`, `denied`, or `authorized` |

Only non-empty values are included. This method returns no `gaid` and no `oppref`.

**Events tracked via Superwall webhook:**

| Superwall Event | Datalyr Event | Has Revenue |
|---|---|---|
| `initial_purchase` | `subscription_started` | Yes |
| `renewal` | `subscription_renewed` | Yes |
| `non_renewing_purchase` | `purchase` | Yes |
| `cancellation` | `subscription_cancelled` | No |
| `expiration` | `subscription_expired` | No |
| `billing_issue` | `billing_failed` | No |
| `uncancellation` | `subscription_reactivated` | No |
| `product_change` | `subscription_changed` | No |
| `subscription_paused` | `subscription_paused` | No |

### 4b. RevenueCat

**In Datalyr Dashboard:**
1. Open **Sources**
2. Click **connect** next to RevenueCat
3. Enter your RevenueCat **Project ID**
4. Copy the generated **webhook URL**

**In RevenueCat Dashboard:**
1. Go to **Project Settings > Integrations > Webhooks**
2. Click **Add new configuration**
3. Name it "Datalyr"
4. Paste the Datalyr webhook URL
5. (Recommended) Set an **Authorization Header** value -- paste the same value in Datalyr
6. Select **Production** events
7. Click **Save**

**In Your Code -- Pass Attribution to RevenueCat:**
```swift
import DatalyrSDK
import RevenueCat

// After BOTH SDKs are initialized
let attrs = DatalyrSDK.shared.getRevenueCatAttributes()
Purchases.shared.attribution.setAttributes(attrs)
```

**Returned attribute keys (reserved `$`-prefixed):**

| Key | Description |
|---|---|
| `$datalyrId` | Datalyr visitor ID |
| `$mediaSource` | Acquisition source |
| `$campaign` | Campaign name |
| `$adGroup` | Ad group / adset |
| `$ad` | Ad identifier |
| `$keyword` | Search keyword |
| `$idfa` | iOS Advertising ID (only if ATT authorized) |
| `$attConsentStatus` | ATT consent status string |

**ATT status mapping for `$attConsentStatus`:**

| ATT Value | String |
|---|---|
| 0 | `notDetermined` |
| 1 | `restricted` |
| 2 | `denied` |
| 3 | `authorized` |

**Custom attributes (also returned):**

| Key | Description |
|---|---|
| `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content` | UTM parameters |
| `lyr` | Datalyr tracking link ID |
| `fbclid`, `gclid`, `ttclid`, `wbraid`, `gbraid` | Ad click IDs |
| `network` | Ad network |
| `creative_id` | Creative ID |

**Events tracked via RevenueCat webhook:**

| RevenueCat Event | Datalyr Event | Has Revenue |
|---|---|---|
| `INITIAL_PURCHASE` | `subscription_started` | Yes |
| `RENEWAL` | `subscription_renewed` | Yes |
| `NON_RENEWING_PURCHASE` | `purchase` | Yes |
| `CANCELLATION` | `subscription_cancelled` | No |
| `UNCANCELLATION` | `subscription_reactivated` | No |
| `EXPIRATION` | `subscription_expired` | No |
| `BILLING_ISSUE` | `billing_failed` | No |
| `PRODUCT_CHANGE` | `subscription_changed` | No |
| `SUBSCRIPTION_PAUSED` | `subscription_paused` | No |
| `SUBSCRIPTION_EXTENDED` | `subscription_extended` | No |
| `TRANSFER` | `subscription_transferred` | No |
| `REFUND_REVERSED` | `refund_reversed` | Yes |

### 4c. No Payment Provider?

- Contact us at hello@datalyr.com and we'll help you get set up
- Or use `trackPurchase()` directly if you handle billing yourself (only after confirming a real charge, not on trial start)

**Links:** [Superwall Integration](https://docs.datalyr.com/integrations/superwall) | [RevenueCat Integration](https://docs.datalyr.com/integrations/revenuecat)

---

## Step 5: Install the Web SDK

**WHY:** The web SDK tracks users on your landing pages. When a user clicks an ad, lands on your page, then installs your app -- the web SDK captured the attribution data (click IDs, UTMs, IP) that the mobile SDK will match against. This is how web-to-app attribution works.

### npm Package (Recommended)

The npm package is the recommended approach -- it bundles into your own domain for better privacy, avoids ad blockers, and gives you full TypeScript support.

```bash
npm install @datalyr/web
```

```javascript
import datalyr from '@datalyr/web';

datalyr.init({
  workspaceId: 'YOUR_WORKSPACE_ID'
});
```

### Script Tag (Alternative)

For sites without a build system, add to your landing page `<head>`:
```html
<script defer src="https://track.datalyr.com/dl.js"
  data-workspace-id="YOUR_WORKSPACE_ID">
</script>
```

Get your Workspace ID from **Settings > General** in the Datalyr dashboard.

### What the Web SDK Captures Automatically

- Page views
- UTM parameters (`utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`)
- Ad click IDs (`fbclid`, `gclid`, `ttclid`, `twclid`, `li_click_id`, `msclkid`)
- Referrer data
- Visitor ID (stored in cookie)
- IP address and user agent

**Links:** [Web SDK Docs](https://docs.datalyr.com/sdks/web)

---

## Step 6: Connect Your Ad Platforms

Datalyr sends conversions to ad platforms **server-side** via their APIs (Meta CAPI, Google Ads API, TikTok Events API). **You do NOT need the Facebook SDK, TikTok SDK, or Google SDK in your app.**

### Meta (Facebook/Instagram)

1. In Datalyr, open **Sources**
2. Click **connect** on Meta
3. Authorize your Meta Business account
4. Select your **Meta Pixel**

### TikTok

1. In Datalyr, open **Sources**
2. Click **connect** on TikTok
3. Authorize your TikTok Ads account
4. Select your **TikTok Pixel**

### Google Ads

1. In Datalyr, open **Sources**
2. Click **connect** on Google
3. Authorize your Google Ads account
4. Select your **conversion actions**

### Apple Search Ads

Apple Search Ads attribution is handled automatically by the Datalyr SDK. No dashboard setup required — the SDK uses Apple's AdServices framework to fetch attribution data on first launch (iOS 14.3+).

**What happens automatically:**
- On first app launch, the SDK checks if the install came from an Apple Search Ads campaign
- If attributed, the data is included in all events with the `asa_` prefix
- No additional code or configuration needed

**Access the data in your code:**
```swift
if let asa = DatalyrSDK.shared.getAppleSearchAdsAttribution() {
    if asa.attribution {
        print(asa.campaignId)       // Campaign ID
        print(asa.campaignName)     // Campaign name
        print(asa.adGroupId)        // Ad group ID
        print(asa.adGroupName)      // Ad group name
        print(asa.keyword)          // Search keyword that triggered the ad
        print(asa.keywordId)        // Keyword ID
        print(asa.clickDate)        // Click date
        print(asa.conversionType)   // "Download" or "Redownload"
        print(asa.orgId)            // Organization ID
        print(asa.orgName)          // Organization name
        print(asa.region)           // Region/country code
    }
}
```

**Fields automatically added to all events:**

| Event Field | Description |
|---|---|
| `asa_campaign_id` | Campaign ID |
| `asa_campaign_name` | Campaign name |
| `asa_ad_group_id` | Ad group ID |
| `asa_ad_group_name` | Ad group name |
| `asa_keyword_id` | Keyword ID |
| `asa_keyword` | Search keyword |
| `asa_org_id` | Organization ID |
| `asa_org_name` | Organization name |
| `asa_click_date` | Date of the ad click |
| `asa_conversion_type` | Conversion type |

These fields are included automatically — you don't need to pass them manually. They flow through to your conversion rules and postbacks so your Apple Search Ads campaigns get proper attribution.

**Links:** [Meta Ads](https://docs.datalyr.com/integrations/meta-ads) | [TikTok Ads](https://docs.datalyr.com/integrations/tiktok-ads) | [Google Ads](https://docs.datalyr.com/integrations/google-ads)

---

## Step 7: Set Up Conversion Rules

Conversion rules tell Datalyr which in-app events to send back to which ad platforms as conversions.

**In Datalyr Dashboard:**
1. Open **Conversions**
2. Click **create rule**
3. Select your **trigger event** (e.g., `subscription_started`)
4. Choose the **target platform** (Meta, Google, TikTok)
5. Select the **platform event name** (e.g., `Purchase` for Meta)
6. Set the **value**: Dynamic (from event data) or Static (fixed amount)
7. Click **Save** -- it's active immediately

### Common Rules for Mobile Apps

| Datalyr Event | Meta Event | Google Event | TikTok Event |
|---|---|---|---|
| `subscription_started` | `Purchase` | `purchase` | `CompletePayment` |
| `purchase` | `Purchase` | `purchase` | `CompletePayment` |
| `signup` | `Lead` | `sign_up` | `Registration` |
| `app_download_click` | `Lead` | `page_view` | `ClickButton` |

You can create multiple rules for the same event to send to multiple platforms.

**Links:** [Conversion Rules](https://docs.datalyr.com/integrations/conversion-rules)

---

## Step 8: Set Up App Campaigns (Web-to-App)

This is the core of how Datalyr works for mobile apps. Run your mobile app ads as **web campaigns** (Meta Sales, TikTok Traffic, Google Ads) through your own domain. Because these are real web campaigns landing on a page you own, ad platforms treat them as regular website traffic — **full-funnel attribution and no per-campaign adset cap.**

### How It Works

1. **User clicks your ad** -- Lands on a page on YOUR domain with the Datalyr web SDK
2. **SDK captures attribution** -- Click IDs (fbclid, ttclid, gclid), UTMs, ad cookies (_fbp, _fbc, _ttp), visitor ID, IP address
3. **User redirects to App Store** -- Either via a button click (prelander) or automatically (redirect page)
4. **User installs and opens app** -- Mobile SDK matches the user:
   - **iOS**: IP matching against recent web events (~90%+ for immediate installs), email fallback on `identify()`
5. **In-app events fire** -- Conversions are sent to Meta/TikTok/Google server-side via Datalyr postbacks

### Why This Works

Ad platforms apply mobile-specific restrictions (SKAN, ATT, limited adsets) only when you select "App Installs" as the campaign objective. When you use a web objective like "Sales" or "Traffic", the ad platform treats it as a regular website campaign. Your landing page is a real web page -- the Datalyr web SDK captures all attribution, then the user continues to the App Store.

### Prerequisites

Before setting up App Campaigns, make sure you have:

- [ ] Datalyr web SDK installed on your domain (Step 5)
- [ ] Datalyr mobile SDK installed in your app (Step 2)
- [ ] Conversion rules configured (Step 7)
- [ ] A domain you control for hosting the landing page
- [ ] At least one ad platform connected (Step 6)

### 8a. Create an App Link

1. In Datalyr, open **Track**
2. Create a link and select **App Link**
3. Enter your page URL (e.g., `https://yourapp.com/download`)
4. Give the link a name (e.g., "Meta Spring Campaign")
5. Optionally add a tracking ID (`lyr`) for segmentation
6. Add UTM parameters if needed
7. Copy the generated tracking URL

Use this URL in your ad campaigns. The app store URL goes in your page code (in `trackAppDownloadClick()`), not in the dashboard.

### 8b. Set Up Your Landing Page

Host one of these page types on your domain (e.g., `yourapp.com/download`).

#### Option A: Prelander (Recommended)

A real landing page with content and a download button. Better for:
- Ad platform compliance (real page with content)
- Higher conversion intent (user actively clicks download)
- Email capture for fallback attribution on iOS
- Lower risk of being flagged for thin content

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Download Your App</title>
  <script src="https://track.datalyr.com/dl.js" data-workspace-id="YOUR_WORKSPACE_ID"></script>
</head>
<body>
  <!-- Add your own design, content, and styling -->
  <h1>Download Our App</h1>
  <p>Get the best experience on mobile.</p>

  <button id="ios-download">Download for iOS</button>
  <button id="android-download">Download for Android</button>

  <script>
    document.getElementById('ios-download').addEventListener('click', function() {
      Datalyr.trackAppDownloadClick({
        targetPlatform: 'ios',
        appStoreUrl: 'https://apps.apple.com/app/idXXXXXXXXXX'
      });
    });
    document.getElementById('android-download').addEventListener('click', function() {
      Datalyr.trackAppDownloadClick({
        targetPlatform: 'android',
        appStoreUrl: 'https://play.google.com/store/apps/details?id=com.example.app'
      });
    });
  </script>
</body>
</html>
```

Replace `YOUR_WORKSPACE_ID` and the app store URLs with your actual values.

**What `trackAppDownloadClick()` does:**
1. Fires an `app_download_click` event with all captured attribution data
2. Stores the visitor's click IDs, UTM parameters, IP address, and user agent
3. Redirects the user to the specified app store URL

#### Option B: Redirect Page

Automatic redirect -- no visible content, user goes straight to App Store:

```html
<!DOCTYPE html>
<html>
<head>
  <script src="https://track.datalyr.com/dl.js" data-workspace-id="YOUR_WORKSPACE_ID"></script>
  <script>
    window.addEventListener('DOMContentLoaded', function() {
      var isAndroid = /android/i.test(navigator.userAgent);
      Datalyr.trackAppDownloadClick({
        targetPlatform: isAndroid ? 'android' : 'ios',
        appStoreUrl: isAndroid
          ? 'https://play.google.com/store/apps/details?id=com.example.app'
          : 'https://apps.apple.com/app/idXXXXXXXXXX'
      });
    });
  </script>
</head>
<body></body>
</html>
```

> **WARNING:** Meta may flag redirect pages with no visible content as low-quality landing pages or cloaking. Use the prelander approach if compliance is a concern.

> **WARNING:** JavaScript is required. Server-side redirects (301/302), nginx redirects, Cloudflare Page Rules, and DNS redirects do NOT work. The Datalyr web SDK must execute in the browser.

### 8c. Configure Ad Campaigns

#### Meta (Facebook/Instagram)

1. In Meta Ads Manager, click **+ Create**
2. Campaign objective: **Sales**
3. At ad set level, Conversion section: select **Website** as conversion location
4. Select your **dataset** (the Meta Pixel connected under **Sources**)
5. Select the **conversion event** to optimize for (must match your conversion rule, e.g., `purchase`)
6. Under Placements: **Mobile only**, correct OS
7. At ad level: paste your landing page URL into **Website URL**
8. Add UTM parameters:
```
?utm_source=facebook&utm_medium=cpc&utm_campaign={{campaign.name}}&utm_content={{adset.name}}&utm_term={{ad.name}}
```
9. Launch

Privacy-compliant. No per-campaign adset cap. Unlimited optimization signals.

#### TikTok

1. Campaign objective: **Website Conversions** or **Traffic**
2. Paste landing page URL as **destination URL**
3. Select the **TikTok Pixel** connected in Datalyr
4. Select **conversion event** (must match conversion rule)
5. Target **mobile devices**, correct OS
6. Add UTM parameters:
```
?utm_source=tiktok&utm_medium=cpc&utm_campaign=__CAMPAIGN_NAME__&utm_content=__AID_NAME__&utm_term=__CID_NAME__
```
7. Launch

#### Google Ads

1. Campaign type: **Performance Max** or **Search**
2. Use landing page URL as **landing page**
3. Select **conversion action** from Datalyr
4. Add UTM parameters:
```
?utm_source=google&utm_medium=cpc&utm_campaign={campaignid}&utm_content={adgroupid}&utm_term={keyword}
```
5. Launch

### 8d. How iOS Attribution Works

**IP Matching (~90%+ accuracy for immediate installs):**
1. Web SDK records visitor's IP, user agent, and all attribution data when `trackAppDownloadClick()` fires
2. After install, mobile SDK sends the device's IP address
3. Datalyr matches the mobile IP against recent `app_download_click` events from the same IP within 24 hours
4. If match found, the app user is linked to the web visitor

**Email Fallback (for delayed installs, VPN changes):**
1. If IP matching fails (user installs later, switches networks, uses VPN)
2. When user signs up/logs in, your app calls `identify()` with the user's email
3. Datalyr matches the email against previously identified web visitors
4. If match found, app user is linked to the original web visitor

**This is why calling `identify()` with email is critical.** Without it, if IP matching fails, attribution is lost.

### 8e. Important Notes

- **Host on YOUR domain** -- not shared domains or URL shorteners
- **JavaScript required** -- server-side redirects don't work (dl.js must run in browser)
- **Redirect page latency** -- adds ~100-200ms for SDK to load
- **Prelander is safer** for ad platform compliance (especially Meta)
- **Target mobile-only** in ad campaigns -- desktop users can't install mobile apps
- **Add terms & privacy links** to prelander for Meta compliance

**Links:** [App Campaigns](https://docs.datalyr.com/features/app-campaigns) | [Track Links](https://docs.datalyr.com/features/track-links)

---

## Step 9: App Tracking Transparency (iOS 14.5+)

ATT is **not required** for web-to-app campaigns (that's the whole point). But if the user grants permission, it improves match quality by providing IDFA.

```swift
import AppTrackingTransparency

// Request after onboarding, not on first launch
ATTrackingManager.requestTrackingAuthorization { status in
    Task {
        // updateTrackingAuthorization takes a UInt?, not a Bool
        await DatalyrSDK.shared.updateTrackingAuthorization(status: status.rawValue)

        // After the ATT response, re-pass attributes to include IDFA
        let attrs = DatalyrSDK.shared.getSuperwallAttributes() // or getRevenueCatAttributes()
        Superwall.shared.setUserAttributes(attrs)
    }
}
```

---

## Step 10: SKAdNetwork (Optional)

SKAdNetwork is an optional iOS 14+ feature for conversion value tracking. Not needed if you're using web-to-app campaigns with Superwall/RevenueCat webhooks.

> **WARNING: Set `skadTemplate` at initialization.** Without it, `getConversionValue(for:properties:)` returns `nil` and `trackWithSKAdNetwork()` sends no conversion update.

```swift
// Initialize with template
let config = DatalyrConfig(
    apiKey: "dk_your_api_key",
    skadTemplate: "subscription" // or "ecommerce", "gaming"
)
try await DatalyrSDK.shared.initialize(config: config)

// Track with automatic SKAN encoding
await DatalyrSDK.trackWithSKAdNetwork("purchase", eventData: [
    "value": 99.99,
    "currency": "USD"
])

// Test conversion value before production
let value = DatalyrSDK.shared.getConversionValue(
    for: "purchase",
    properties: ["revenue": 99.99]
)
print("Conversion value: \(value ?? 0)") // 0-63
```

**Templates:**
- `ecommerce` -- purchase events, revenue ranges
- `gaming` -- level completion, IAP, retention
- `subscription` -- trial starts, conversions, renewals

---

## Step 11: Verify Everything Works

### Check SDK Events

With `debug: true`, the console prints lines like:
```
[Datalyr] Initializing Datalyr SDK...
[Datalyr] Event sent: app_install
[Datalyr] Event sent: session_start
```

Check SDK status:
```swift
let status = DatalyrSDK.shared.getStatus()
print("Initialized: \(status.initialized)")
print("Visitor ID: \(status.visitorId)")
print("Queue size: \(status.queueStats.queueSize)")
print("Online: \(status.queueStats.isOnline)")
```

Force flush events:
```swift
await DatalyrSDK.shared.flush()
```

### Check Webhook Events

1. Make a test purchase (Sandbox/TestFlight)
2. In Datalyr, open **Events**
3. Filter by source (`superwall` or `revenuecat`)
4. The event appears within 30 seconds
5. In Superwall/RevenueCat webhook dashboard, check for `200` response

### Check Attribution

```swift
let attribution = DatalyrSDK.shared.getAttributionData()
print("Source: \(attribution.utmSource ?? "none")")
print("Campaign: \(attribution.utmCampaign ?? "none")")
print("Click ID: \(attribution.fbclid ?? attribution.gclid ?? attribution.ttclid ?? "none")")
```

`getDeferredAttributionData()` always returns `nil`. `getLastError()` always returns `nil`. Use `getAppleSearchAdsAttribution()` and `getStatus()` instead.

### Check Postbacks

1. In Datalyr, check postback delivery status under **Conversions**
2. Verify events appear in your ad platform:
   - **Meta**: Events Manager > Data Sources > Your Pixel > Event Activity
   - **Google**: Google Ads > Tools > Conversions
   - **TikTok**: TikTok Ads Manager > Events > Event History

> **Note:** Test mode conversions don't appear in ad platform reports but are visible in their event testing tools.

**Links:** [Tracking Not Working](https://docs.datalyr.com/troubleshooting/tracking-not-working) | [Missing Conversions](https://docs.datalyr.com/troubleshooting/missing-conversions) | [Postback Debugging](https://docs.datalyr.com/troubleshooting/postback-debugging)

---

## Best Practices

1. **Only use SDK for behavioral events if using Superwall/RevenueCat** -- `trackPurchase()` fires before payment is confirmed, counting trials and failed payments as revenue. Use webhooks for subscription revenue.

2. **Always pass attributes to your payment provider after both SDKs init** -- This links ad data to revenue. Without it, conversions aren't attributed to campaigns.

3. **Call `identify()` with email as early as possible** -- Critical for iOS web-to-app fallback attribution. Without email, IP-only matching degrades over time.

4. **Use prelander, not redirect, for App Campaigns** -- Ad platforms (especially Meta) flag redirect pages as cloaking/low-quality.

5. **Initialize SDK early** -- In `AppDelegate` or `App.init()`, before any other tracking calls.

6. **Set `debug: false` in production** -- Debug mode logs everything to console.

7. **Call `flush()` before critical operations** -- After purchase events, before logout. Ensures events aren't lost if app crashes.

8. **Don't track the same event client AND server** -- Creates duplicates. Don't call `trackPurchase()` AND have webhooks send the same purchase event.

9. **Call `getSuperwallAttributes()` / `getRevenueCatAttributes()` again after ATT prompt** -- Includes IDFA if user authorized.

10. **Use dynamic values for purchase conversion rules** -- Static values don't reflect actual order amounts.

---

## Common Mistakes

| Mistake | What Goes Wrong | Fix |
|---|---|---|
| Using `trackPurchase()` with Superwall/RevenueCat | Counts trials and failed payments as revenue | Use webhooks only for subscription revenue |
| Not calling `identify()` with email | iOS web-to-app attribution fails (no fallback) | Always identify with email after signup/login |
| Not passing attributes to Superwall/RevenueCat | Revenue events not attributed to campaigns | Call `getSuperwallAttributes()`/`getRevenueCatAttributes()` after SDK init |
| Server-side redirects for landing pages | Web SDK never loads, attribution data lost | Must use JavaScript-based page |
| Wrong API key format | Auth errors | Must start with `dk_`, from **Settings → API** |
| Not setting up conversion rules | Events tracked but never sent to ad platforms | Create a rule under **Conversions** |
| Forgetting `reset()` on logout | Next user's events attributed to previous user | Always call `reset()` on logout |
| Initializing SDK multiple times | Race conditions, double events | Initialize ONCE in AppDelegate/App init |

---

## FAQ

### Setup & SDKs

**Do I need the Facebook/TikTok/Google SDK in my app?**
No. Datalyr handles all conversions server-side via postbacks. No ad platform SDKs needed in your app.

**Do I need to track purchases in the SDK?**
No, if using Superwall/RevenueCat. Revenue is tracked via webhooks. Only use `trackPurchase()` if you handle billing yourself.

**Can I use the same webhook URL for iOS and Android?**
Yes.

**Does Datalyr replace AppsFlyer/Adjust?**
Yes -- install attribution, SKAN conversion values, and campaign-to-revenue matching without per-MAU pricing.

**Can I use both Superwall and RevenueCat?**
Yes, each gets its own webhook URL.

**Does tracking work offline?**
Yes. Events queue locally, up to 1000 by default, and send when connectivity returns.

### Attribution

**Do I need IDFA/ATT?**
Optional. Improves match quality but not required. Web-to-app campaigns work without it.

**What's the attribution window?**
30 days default in Datalyr. Platform-specific: Meta 7-day click / 1-day view, Google 90-day click / 1-day view, TikTok 28-day click / 1-day view.

**How accurate is web-to-app attribution on iOS?**
~90%+ for same-session installs (IP matching). Higher with email fallback via `identify()`.

**Why do I need to call `identify()` with email?**
It's the iOS fallback. If IP matching fails (VPN, delayed install, network change), email matching connects the web visitor to the app user.

### Revenue & Conversions

**How do I see my attribution data?**
Open **Reports**.

**Why aren't my conversions showing in Meta/Google/TikTok?**
Check: conversion rules exist, ad platform connected, user has valid click ID (fbclid/gclid/ttclid), event within attribution window.

**What events does the webhook track?**
Purchases, renewals, cancellations, expirations, billing issues, refunds, trial conversions, product changes.

### Technical

**What gets tracked automatically?**
`app_install`, `session_start`, `session_end`, `$att_status`, and `$web_attribution_matched`. Nothing auto-sends `app_update`.

**Will Datalyr slow down my app?**
No. The queue drains 10 events every 10 seconds and sends one HTTP request per event. Nothing blocks the main thread.

**Is SKAdNetwork required?**
No. Optional iOS 14+ feature. Not needed if using web-to-app campaigns with Superwall/RevenueCat webhooks.

---

## Troubleshooting

### Events Not Appearing

1. Check API key is correct (starts with `dk_`)
2. Enable `debug: true` -- look for `[Datalyr]` console logs
3. Check `getStatus()` -- is `initialized` true? Is queue growing?
4. Call `flush()` to force send
5. Check network -- are requests hitting `ingest.datalyr.com`?
6. Open **Events** in Datalyr

### Attribution Not Matching (Web-to-App)

1. Is web SDK loading on your landing page? Check browser console for `dl.js`
2. Is `trackAppDownloadClick()` firing before the redirect?
3. Is mobile SDK initialized in your app?
4. Did user install from the same IP? (check for VPN/network change)
5. Is `identify()` called with email? (iOS fallback)
6. Is attribution within window? (24hr for IP, 30d for email)

### Postbacks Not Sending

1. Do conversion rules exist for the event? (case-sensitive names!)
2. Is the ad platform connected under **Sources**?
3. Does the event have a valid click ID (fbclid/gclid/ttclid)?
4. Check Dashboard for postback delivery status
5. Check ad platform for received conversions

### Build Errors

```bash
cd ios
pod deintegrate
pod cache clean --all
pod install
```

Clean build: **Cmd+Shift+K** in Xcode
Reset packages: **File > Packages > Reset Package Caches**

### SKAdNetwork Not Working

- iOS 14.0+ required (16.1+ for SKAN 4.0)
- Is `skadTemplate` set in config?
- Using `trackWithSKAdNetwork()` instead of `track()`?
- SKAdNetwork IDs added to Info.plist?

**Links:** [Tracking Not Working](https://docs.datalyr.com/troubleshooting/tracking-not-working) | [Missing Conversions](https://docs.datalyr.com/troubleshooting/missing-conversions) | [Postback Debugging](https://docs.datalyr.com/troubleshooting/postback-debugging) | [Data Discrepancies](https://docs.datalyr.com/troubleshooting/data-discrepancies) | [Integration Errors](https://docs.datalyr.com/troubleshooting/integration-errors)

---

## API Reference

### Initialization
| Method | Description |
|---|---|
| `DatalyrSDK.shared.initialize(config:)` | Initialize the SDK. Must call before anything else. |

### Event Tracking
| Method | Description |
|---|---|
| `DatalyrSDK.shared.track(_:eventData:)` | Track a custom event |
| `DatalyrSDK.shared.screen(_:properties:)` | Track a screen view. Sends the event name `pageview`. |
| `DatalyrSDK.shared.trackPurchase(value:currency:productId:)` | Track a purchase |
| `DatalyrSDK.shared.trackSubscription(value:currency:plan:)` | Track a subscription |
| `DatalyrSDK.shared.trackRevenue(_:properties:)` | Track a revenue event |
| `DatalyrSDK.trackWithSKAdNetwork(_:eventData:)` | Track with SKAN conversion encoding |

### User Identity
| Method | Description |
|---|---|
| `DatalyrSDK.shared.identify(_:properties:)` | Identify a user |
| `DatalyrSDK.shared.alias(_:previousId:)` | Associate new user ID with previous |
| `DatalyrSDK.shared.reset()` | Clear user data, rotate anonymous and visitor IDs, start a new session |
| `DatalyrSDK.shared.getAnonymousId()` | Get persistent anonymous device ID |

### Attribution
| Method | Description |
|---|---|
| `DatalyrSDK.shared.getAttributionData()` | Get captured attribution data |
| `DatalyrSDK.shared.setAttributionData(_:)` | Set attribution manually |
| `DatalyrSDK.shared.getDeferredAttributionData()` | Always returns `nil`. Use `getAppleSearchAdsAttribution()`. |
| `DatalyrSDK.shared.getAppleSearchAdsAttribution()` | Get Apple Search Ads data (iOS 14.3+) |
| `DatalyrSDK.shared.updateTrackingAuthorization(status:)` | Update ATT status. Takes `UInt?`, not `Bool`. |

### Integrations
| Method | Description |
|---|---|
| `DatalyrSDK.shared.getSuperwallAttributes()` | Get attrs formatted for Superwall |
| `DatalyrSDK.shared.getRevenueCatAttributes()` | Get attrs formatted for RevenueCat |

### SKAdNetwork
| Method | Description |
|---|---|
| `DatalyrSDK.shared.getConversionValue(for:properties:)` | Preview conversion value without sending |

### Queue & Status
| Method | Description |
|---|---|
| `DatalyrSDK.shared.flush()` | Send all queued events immediately |
| `DatalyrSDK.shared.getStatus()` | Get SDK status (initialized, queue, online) |

---

## Need Help?

- **Full docs:** [docs.datalyr.com](https://docs.datalyr.com)
- **iOS SDK:** [docs.datalyr.com/sdk-reference/ios](https://docs.datalyr.com/sdk-reference/ios)
- **Superwall:** [docs.datalyr.com/integrations/superwall](https://docs.datalyr.com/integrations/superwall)
- **RevenueCat:** [docs.datalyr.com/integrations/revenuecat](https://docs.datalyr.com/integrations/revenuecat)
- **App Campaigns:** [docs.datalyr.com/features/app-campaigns](https://docs.datalyr.com/features/app-campaigns)
- **Conversion Rules:** [docs.datalyr.com/integrations/conversion-rules](https://docs.datalyr.com/integrations/conversion-rules)
- **Web SDK:** [docs.datalyr.com/sdks/web](https://docs.datalyr.com/sdks/web)
- **Email:** hello@datalyr.com
