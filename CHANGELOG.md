# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] - 2026-01

### Added
- **AdAttributionKit Support** (iOS 17.4+) - Unified bridge for Apple's new attribution framework
- **IDFA Client-Side Capture** - Automatic IDFA capture when ATT authorized for improved Meta Event Match Quality
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
