# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- **TR-26: `PrivacyInfo.xcprivacy` now accurately declares tracking.** The manifest said
  `NSPrivacyTracking=false` with empty domains and every data type `Linked/Tracking=false`,
  while the SDK reads the IDFA when ATT-authorized, attaches it to events, and forwards
  click-ids / hashed email+phone / purchases to third-party ad CAPI. It now declares
  `NSPrivacyTracking=true`, the `ingest.datalyr.com`/`api.datalyr.com` tracking domains, and
  DeviceID / EmailAddress / PhoneNumber / PurchaseHistory / CoarseLocation / ProductInteraction
  as Linked+Tracking (Analytics + ThirdPartyAdvertising). **App Store implication:** apps
  embedding this SDK must reflect this tracking in their App Privacy "nutrition label"; this
  reflects behavior that was already occurring.

### Added
- **TR-18: caller-supplied `event_id` for idempotent delivery.** If `eventData["event_id"]` is a
  non-empty string it becomes the wire `eventId` (and is stripped from properties), mirroring the
  Node SDK — so a client that double-tracks a purchase alongside a Stripe/RevenueCat webhook has a
  deterministic server-side dedup key. Omitted/empty → a fresh UUID (unchanged).
- **TR-17: re-engagement deep links now emit a `$deep_link` event.** `handleDeepLink` persisted
  the extracted `fbclid`/`gclid`/`ttclid`/`lyr` locally (and surfaced them to Superwall/RevenueCat
  client attributes) but fired **no event**, and `createEventPayload` merges attribution only
  into `app_install` — so a day-5 post-install ad-click deep link never reached Datalyr ingest,
  and server attribution / CAPI couldn't see the re-engagement touch. `handleDeepLink` now
  returns the extracted params and the SDK emits a `$deep_link` event (`source: "deep_link"` +
  the click-ids + lyr) from both the live and the buffered/replayed paths.

### Fixed
- **TR-21 (data loss): the install flag was written BEFORE `app_install` was enqueued.** A
  crash/kill between the flag write and the enqueue lost `app_install` — install attribution, the
  single most valuable mobile event — permanently. The flag is now set AFTER `track()` returns
  (event durably queued), so an interrupted first launch re-fires `app_install` next launch.
- **TR-28 (identity bleed): `reset()` didn't clear the multi-touch journey.** It wiped current
  attribution but left the persisted journey (touchpoints / first-last touch), so a
  logout→login-as-B carried user A's journey into B. `reset()` now also calls
  `JourneyManager.clearJourney()`.
- **TR-16 (data loss): a launch-time `track()` could be lost to an init race.** `track()`
  read `initialized` in a `guard` *outside* `preInitLock`, then appended to `preInitQueue`
  *inside* the lock without re-checking — so `initialize()`'s atomic drain (which empties the
  buffer and sets `initialized=true` under the same lock) could interleave, and the event
  landed in the already-drained buffer and was never sent. `track()` is the highest-volume
  path and fires exactly at launch. It now re-checks `initialized` inside the lock (mirroring
  `identify()`/`alias()`/`routeDeepLink()`): if init won the race, it falls through to normal
  processing instead of buffering into the void.
- **TR-05 (data loss): a full event queue silently dropped the oldest event with no
  dead-letter.** `enqueue()` did a bare `queue.removeFirst()` (+ debug log) once
  `maxQueueSize` (default **100**) was reached — oldest-first is the offline backlog, so any
  offline period producing >100 events lost everything beyond the newest 100, purchases
  included. Now: the default cap is **1000**; an overflow evicts the oldest **non-critical**
  event first (purchases / value-bearing conversions are retained) and routes the evicted
  event through `deadLetter()` (capped, replayed on the next launch) instead of dropping it.
- **9.B.1 (data loss): the client-side rate limiter dropped burst/backlog events —
  including purchases — instead of pacing them.** The fixed-window `RateLimiter` THREW
  `rateLimitExceeded` past 100 events/min, `shouldRetry` classified that as non-retryable
  (the send failed on its first attempt), and the queue burned one of its 3 retries per
  drain pass — so an offline (airplane-mode) backlog of >100 events draining in one burst
  dead-lettered the overflow. The limiter is now a sliding 60s window that WAITS
  (backpressure) until a slot frees — bounded, so a send can never hang; past the bound it
  proceeds and defers to the server's 429, which is already handled as retry-free
  backpressure (FSR-31). A backlog now delivers ALL events with zero dead-letters, just
  slower. Mirrors the React Native SDK's `enforceRateLimit()` fix.

## [2.1.7] - 2026-06-10

Full-stack review (FULL_STACK_REVIEW_2026-06-10) fix pass. Fixes a host-app crash,
several SKAN under-reporting bugs, dead session/flush timers, pre-init drop paths, and
cross-user identity contamination. 14 new XCTests (85 total, green).

### Fixed
- **FSR-1 (crash): `track()`/`identify()` could crash the host app on `Date`/`URL`/`UUID`
  property values.** `validateEventData` and `persistUserData` called
  `JSONSerialization.data(withJSONObject:)` on the raw caller dict, which raises an
  *uncatchable* Objective-C `NSInvalidArgumentException` for non-JSON types (the `do/catch`
  never fires). Now guarded with `isValidJSONObject` and sanitized to the wire shape
  (`Date`→ISO8601, `URL`→absoluteString) — these are SDK-supported inputs, so they're kept,
  not rejected, and never crash.
- **FSR-3 (SKAN): conversion value reset to 0/low on every cold launch (iOS 17.4+).** The
  per-launch AdAttributionKit registration sent `updatePostbackConversionValue(0, .low, …)`
  each time, clobbering any in-window value. The 0-value registration now fires **once per
  install** (persisted flag).
- **FSR-7 (SKAN): the main `trackWithSKAdNetwork` path bypassed the monotonic/lock guard.**
  It called the OS update APIs directly, so a later low-funnel event (e.g. `view_item`)
  downgraded an earlier higher value. It now routes through a single guarded updater that
  **persists the high-water fine+coarse+locked across launches** and only sends increases.
  (Encoder bit schema unchanged — IOS-24.)
- **FSR-87 (SKAN): integer `revenue`/`value` silently lost its tier.** `as? Double` returns
  nil for a native `Int`; now read via `NSNumber` so `["revenue": 50]` encodes the tier.
- **FSR-4 (sessions): the inactivity-timeout `session_end` timer never fired.**
  `AutoEventsManager` still used `Timer.scheduledTimer` from runloop-less cooperative
  threads; replaced with a `DispatchSourceTimer` (mirrors the IOS-6 queue fix).
- **FSR-36 (sessions): timeout measured session AGE, not inactivity, and AutoEvents
  rotation never synced back to the SDK.** Last-activity now anchors the timeout (the stored
  session timestamp is bumped on each tracked event), and AutoEvents pushes a freshly-minted
  session id back to the SDK so payloads/`context.session_id` stay in lockstep.
- **FSR-5 (deep links): install-moment deep links were dropped if `handleDeepLink` ran
  before `initialize()` finished.** URLs are now buffered and replayed before
  `checkAndTrackInstall()`, so `app_install` carries the launch deep link's params.
- **FSR-33 (identity): pre-init `identify()`/`alias()` were silently dropped** (unlike
  `track()`). They're now buffered and replayed after init.
- **FSR-90 (identity): pre-init drain TOCTOU.** `initialized = true` and the buffer
  snapshot+clear now happen in the same lock critical section, so a racing call can't append
  after the drain and be lost.
- **FSR-6 (identity): `reset()` never rotated `anonymousId`** — the server's visitor key — so
  logout→login on a shared device merged two users server-side. `reset()` now regenerates
  `anon_<uuid>` (mirrors the Node SDK NODE-6 fix), clears the SKAN window, and drops the
  web-attribution-checked marker (FSR-93).
- **FSR-32 (identity): no-arg `alias()` defaulted `previousId` to `visitorId`**, which the
  server never keys anonymous events on. Defaults to `currentUserId ?? anonymousId` so the
  link resolves real pre-alias events.
- **FSR-30 (attribution): web→app merge dropped `gbraid`/`wbraid`/`lyr`.** Added gap-fill
  branches (precedence unchanged).
- **FSR-34 (attribution): journey last-touch/touchpoints were re-recorded from stale,
  never-expiring attribution every cold launch**, rolling the 90-day expiry forward and
  inflating `touchpoint_count`. The init-time touch is recorded only when the attribution is
  genuinely new (capture-time gate), carrying the real timestamp.
- **FSR-35 (attribution): `oppref` was missing from `AttributionData.CodingKeys`** — captured
  then lost on relaunch. Added (plus a new `dclid` field — FSR-86).
- **FSR-86 (attribution): `dclid` and other params were whitelisted but never assigned.**
  `dclid` is now captured (ingest supports it); the truly-unused whitelist entries
  (`irclickid`, `fb_click_id`, `fb_action_ids`, `fb_action_types`, `click_id`) were removed.
- **FSR-29 (network): Apple Search Ads fetch had no retry/timeout and blocked init.** Now
  bounded at 10s, retries Apple's documented transient 404 up to 3×, and runs detached so it
  no longer gates `initialized` (which was pushing events past the 50-cap pre-init queue).
- **FSR-31 (network): `429`/`408` were treated as permanent.** They're now retried honoring
  `Retry-After` without counting against the failure/dead-letter budget.
- **FSR-92 (network): the `identify()` web-attribution lookup had no request timeout**
  (inherited 60s). Set to 10s (matching the deferred path).
- **FSR-88 (queue): the dead-letter store was write-only.** Retry-exhausted events are now
  replayed once on the next launch.
- **FSR-84 (queue): queue init overwrote concurrently-enqueued events with the persisted
  snapshot.** Now merges (persisted-first) instead of assigning.
- **FSR-89 (queue): `updateConfig` ignored its argument.** It now applies the new config.
- **FSR-91 (lifecycle): `appWillResignActive` could end the NEXT background task mid-flush.**
  The task id is captured locally and exactly that id is ended (matches the terminate path).

### Notes
- **FSR-25 (unchanged by design):** anonymous events still send `userId = visitorId`
  (`DatalyrHTTPClient.transformForServerAPI`) — a shared server-side contract the web→app
  lyr bridge may depend on. Left as-is.

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

- **SKAdNetwork conversion-value schema rebuilt (was silently dropping purchases).** The old
  templates assigned bits 6 & 7, which overflow the 6-bit (0–63) fine value and clamp to 63 — so
  low-value events (`signup`/`view_item`) reported a *higher* value than `purchase` (max 15). Since
  SKAN only revises the value **upward**, a signup-then-purchase user locked at 63 and the purchase
  + revenue were never recorded. Rewritten to Apple's recommended **mixed model**:
  `fineValue = (funnelRank << 3) | revenueTier` (3 bits funnel rank, down-funnel = higher; 3 bits
  revenue tier), so values fit 0–63 and `purchase` always outranks `signup`. **Coordinated release:**
  your SKAN dashboard schema must be updated to the new value→meaning mapping — see
  `docs-v2/SKAN_CONVERSION_VALUE_SCHEMA_2026-06-03.md`. Confirm the event→rank order matches your LTV model.

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
