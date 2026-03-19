# Changelog

All notable changes to this project will be documented in this file.

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
