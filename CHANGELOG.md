# Changelog

All notable changes to this project will be documented in this file.

## [2.1.6] - 2026-06-03

End-to-end review pass. Unblocks the build on current Xcode, restores a green test
suite (69 tests), and fixes verified attribution-loss and event-delivery bugs.

### Fixed
- **Build no longer fails to compile on Xcode 26 / Swift 6.2.** A long mixed-type `??`
  chain in `getAttributionSummary()` tripped the type-checker ("unable to type-check in
  reasonable time"). Rewritten as an explicit, identical-precedence `if`/`else` ladder.
- **Google iOS click-ids (`gbraid`/`wbraid`) were dropped from every deep link.** They
  were parsed into `ATTRIBUTION_PARAMS` and read by `getRevenueCatAttributes()` but never
  assigned in `processAttributionParameters` — so Google App-campaign attribution (gclid is
  frequently absent in-app under ATT/ITP) was lost. Now captured.
- **`alias()` wrote no identity links.** It emitted event name `alias` (not `$alias`) with
  snake_case `previous_id`/`user_id`, but the ingest link builder matches only `$alias` and
  reads camelCase `previousId`/`userId` — so every alias-based identity merge was silently
  dropped (no `visitor_user_links` row). Now emits `$alias` with both casings (matches the
  Node/RN SDKs). `identify()` was unaffected and already linked correctly.
- **Server-track wire-contract fixes** (the default `useServerTracking=true` path sends a
  Segment-shaped body via `transformForServerAPI`):
  - **`session_id` now travels in `context`**, where the ingest server-track handler reads
    it. It was sent in `properties`, so ingest discarded the SDK's 30-min session and
    synthesized its own hour-bucketed session id for every iOS event.
  - **Web→app bridge now emits `_fbp`/`_fbc`** (the Meta cookie names the attribution
    materialized view + postback actually extract) alongside the bare `fbp`/`fbc`. Only the
    bare keys were sent, which no reader extracts — so recovered web touches contributed no
    fbp/fbc to Meta CAPI, lowering match quality.
  - Fixed the hardcoded stale library `version` in the server payload context (`2.1.1` →
    `2.1.6`) and the `User-Agent` header (`@datalyr/swift/2.0.2` → `2.1.6`); `sdk_version`
    in event_data was already correct.
  - **`att_status` now serializes as a number, not a string.** It's a `UInt`, which Swift's
    `as? Int` cast does not match, so the JSON sanitizer fell through to a string conversion
    and shipped `"0"`/`"3"`. Confirmed against production. (Verified end-to-end with a
    real prod iOS event.)
- **Periodic flush + session-timeout timers never fired.** They were `Timer.scheduledTimer`
  registered on a cooperative-pool thread with no run loop. The flush safety-net is now a
  `DispatchSourceTimer` (fires without a run loop).
- **`flush()` drained only one batch.** A backlog larger than `batchSize` (10) left the rest
  queued. `flush()`/processing now loops until the queue is empty or a batch makes no forward
  progress (so a transient outage doesn't busy-loop).
- **Offline detection was dead.** `setOnlineStatus` had no caller, so the queue never knew it
  was offline and burned the retry budget toward dead-letter during outages. Now driven by
  `NWPathMonitor`.
- **`session_id` divergence.** After a `reset()` or a 30-minute foreground timeout, event
  payloads carried the new session id while `session_start`/`session_end` and the pageview
  `session_id` enrichment kept emitting the stale init-time id. The auto-events session id is
  now synced to the SDK's on both paths.
- **Background-task lifecycle.** The resign-active flush leaked its `beginBackgroundTask`
  assertion until foreground/expiration; it now ends immediately after the flush. The
  terminate flush now runs inside a background-task scope so it gets the OS time budget.

### Notes
- The default **SKAdNetwork conversion-value templates allocate bits 6 and 7, which overflow
  the 6-bit (0–63) fine value and clamp to 63** — so low-value events (e.g. `signup`, `lead`,
  `view_item`) report a *higher* fine value than a `purchase` (which tops out at 15). This is a
  pre-existing schema-design issue that must be coordinated with the advertiser's SKAN dashboard
  configuration; it is flagged for a deliberate redesign and intentionally not changed here.

## [2.1.5] - 2026-05-31

### Changed
- **Web→app email attribution now emits the canonical `$web_attribution_matched` event** (with `match_method: "email"`) instead of the separate `$web_attribution_merged`. The email/`identify()` match path and the IP/deferred match path now fire the same event name, distinguished by `match_method` (`"email"` vs `"ip"`), so the server-side attribution bridges (Meta CAPI recovery, trackable-link `lyr`) recover web attribution for webhook conversions from email matches too. No API changes.

## [1.4.0] - 2026-03

### Removed
- **Meta (Facebook) SDK** - Removed FBSDKCoreKit dependency and all client-side Meta integration code
- **TikTok Business SDK** - Removed TikTokBusinessSDK dependency and all client-side TikTok integration code
- Removed `metaAppId`, `metaClientToken`, `tiktokAppId`, `tiktokEventsAppId`, `tiktokAccessToken` config properties
- Removed all client-side event forwarding to Meta/TikTok (purchase, add_to_cart, etc.)
- Removed deferred deep linking via Meta SDK (`AppLinkUtility.fetchDeferredAppLink`)
- Removed `MetaIntegration.swift`, `TikTokIntegration.swift`, `DatalyrObjCExceptionCatcher`
- Removed `metaEventFailed`/`tiktokEventFailed` error types

### Changed
- Conversion event routing to Meta (CAPI), TikTok (Events API), and Google Ads is now handled entirely server-side via the Datalyr postback system
- IDFA/ATT helpers now use native Apple frameworks directly (ASIdentifierManager, ATTrackingManager) instead of routing through Meta SDK
- Web-to-app attribution is handled via prelanders and IP-based deferred matching

### Migration from v1.3.x
Remove Meta/TikTok config properties from your `DatalyrConfig` initializer:
```swift
// Before (v1.3.x)
let config = DatalyrConfig(
    apiKey: "dk_...",
    metaAppId: "1234567890",          // REMOVE
    metaClientToken: "abc123",        // REMOVE
    enableMetaAttribution: true,      // REMOVE
    forwardEventsToMeta: true,        // REMOVE
    tiktokAppId: "7123456789",        // REMOVE
    tiktokEventsAppId: "...",         // REMOVE
    tiktokAccessToken: "...",         // REMOVE
    enableTikTokAttribution: true,    // REMOVE
    forwardEventsToTikTok: true       // REMOVE
)

// After (v1.4.0)
let config = DatalyrConfig(
    apiKey: "dk_..."
)
```
No other code changes needed. All tracking methods (`trackPurchase`, `trackAddToCart`, etc.) work the same — events are now routed to ad platforms server-side via your Datalyr postback rules.

You can also remove from your Info.plist:
- `FacebookAppID`, `FacebookClientToken`, `FacebookDisplayName`
- `LSApplicationQueriesSchemes` entries for `tiktok`, `snssdk1180`, `snssdk1233`

## [1.3.0] - 2026-01

### Added
- **AdAttributionKit Support** (iOS 17.4+) - Unified bridge for Apple's new attribution framework
- **IDFA Client-Side Capture** - Automatic IDFA capture when ATT authorized for improved ad platform match quality
- `getIDFA()` and `getAdvertiserData()` public methods
- iOS 18.4+ feature detection (geo-level postbacks, overlapping windows, development postbacks)
- `AdAttributionKitBridge.swift` for unified attribution across SKAdNetwork and AdAttributionKit
- Thread safety tests for event queue and HTTP client
- Attribution tests for AdAttributionKit framework detection

### Changed
- Event payloads now include `advertiser_data` with IDFA and ATT status when authorized
- `updateTrackingAuthorization()` now auto-captures IDFA when ATT authorized
- Improved Privacy Manifest with device ID and product interaction declarations

### Fixed
- Thread safety improvements in DatalyrEventQueue and DatalyrHTTPClient

## [1.2.0] - 2025-01

### Added
- Apple Search Ads attribution via AdServices framework (iOS 14.3+)
- `getAppleSearchAdsAttribution()` method to access ASA data
- Automatic `asa_*` fields in all event payloads for ASA attribution
- `tiktokEventsAppId` configuration for separate Events API App ID
- Modern TikTok SDK methods: `logViewContent`, `logInitiateCheckout`, `logCompleteRegistration`, `logSearch`, `logLead`, `logAddPaymentInfo`, `logout`
- Apple Search Ads status in `getPlatformIntegrationStatus()`

### Changed
- Updated TikTok SDK to use modern `trackTTEvent()` API with `TikTokBaseEvent`
- TikTok initialization now requires both `tiktokAppId` and `tiktokEventsAppId`
- Improved TikTok user identification using `identify(withExternalID:externalUserName:phoneNumber:email:)`

### Fixed
- TikTok SDK initialization bug (was using same value for both appId and tiktokAppId)
- Removed unsupported `externalId` parameter from Meta `setUserData()` method

### Removed
- Duplicate `DatalyrSwift.podspec` (consolidated to `DatalyrSDK.podspec`)
- Test apps and examples (DatalyrTestApp/, test-app/, examples/)
- INSTALL.md (merged into README.md)

## [1.1.0] - 2025-01

### Added
- Meta (Facebook) SDK integration with deferred deep linking
- TikTok Business SDK integration
- Platform integration manager for unified SDK control
- User identification forwarding to Meta/TikTok for Advanced Matching
- `getPlatformIntegrationStatus()` method
- `getDeferredAttributionData()` method
- Persistent anonymous ID for cross-session identity resolution
- App Tracking Transparency (ATT) integration

### Changed
- E-commerce events now forward to Meta and TikTok automatically
- Improved attribution tracking with platform-specific click IDs

## [1.0.0] - 2024-12

### Added
- Initial release
- Server-side event tracking with API key authentication
- SKAdNetwork support with conversion value templates
- Attribution tracking (UTM, click IDs, deep links)
- Offline event queue with automatic retry
- Session management with 30-minute timeout
- SwiftUI and UIKit support
- Swift Package Manager and CocoaPods distribution
