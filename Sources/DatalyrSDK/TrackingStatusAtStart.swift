import Foundation
#if canImport(DatalyrSDKLaunch)
import DatalyrSDKLaunch
#endif

/// The ATT status this app process started with.
///
/// iOS opens the declared tracking domain (tracking.datalyr.com) only to processes started
/// after the user allowed tracking: in the launch where the user taps "Allow", requests to
/// it still fail although the status reads authorized. The SDK therefore uses the tracking
/// host only when tracking was already authorized when the process started.
///
/// The value is read by a C constructor when the SDK's code is loaded (before `main()`, so
/// before the app can show the prompt), not when the app first calls the SDK. Memory only,
/// never stored.
internal enum TrackingStatusAtStart {
    /// Raw value from the loader: 0-3, -1 not read, -2 no ATTrackingManager (before iOS 14).
    /// (Swift Package Manager: the DatalyrSDKLaunch target. CocoaPods: the same file, in this
    /// pod, through its public header.)
    static var rawCapturedAtLoad: Int64 {
        return datalyr_att_status_at_process_start()
    }

    #if DEBUG
    /// Test support: replaces the loader's value (nil = unreadable).
    static var overrideForTesting: (() -> UInt?)?
    #endif

    /// 0 notDetermined, 1 restricted, 2 denied, 3 authorized; nil when it could not be read,
    /// which counts as not authorized (the normal host is used).
    static func value() -> UInt? {
        #if DEBUG
        if let override = overrideForTesting { return override() }
        #endif
        let raw = rawCapturedAtLoad
        if raw >= 0 && raw <= 3 { return UInt(raw) }
        if raw == -2 && !PlatformIntegrationManager.trackingAuthorizationFrameworkAvailable {
            return 3 // no App Tracking Transparency on this OS: same as the live status reports
        }
        return nil
    }
}
