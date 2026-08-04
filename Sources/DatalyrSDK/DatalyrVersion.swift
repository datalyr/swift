import Foundation

/// The one place the SDK version is written.
///
/// IOS-20. There used to be **four** independent hardcoded version literals —
/// the transport envelope's `context.version`, `properties.sdk_version`, a
/// *second* `sdk_version` used only by `app_install`, and the `User-Agent`
/// header — plus a fifth stale one in a thrown error message. They drifted, and
/// the drift was invisible because nothing compared them.
///
/// Measured in production 2026-07-25, a single live request carried **three
/// different versions at once**: envelope `2.1.1`, payload `2.1.3`, User-Agent
/// `@datalyr/swift/2.0.2`. `context.version` had been frozen at `2.1.1` across
/// four releases (v2.1.2–v2.1.5) while `sdk_version` moved independently, so
/// version-based rollout tracking could not be trusted on either field.
///
/// Everything that reports a version now reads `DatalyrVersion.current`.
/// `scripts/validate.sh` fails the build if this constant and
/// `DatalyrSDK.podspec` disagree, so a release cannot half-bump again.
///
/// **When releasing: change this line and `DatalyrSDK.podspec` together.**
/// There is no build-time injection — SwiftPM has no equivalent of rollup's
/// `@rollup/plugin-replace`, and reading `Bundle`/Info.plist would report the
/// *host app's* version, not the SDK's.
public enum DatalyrVersion {
    /// Semantic version of this SDK build. Must equal `DatalyrSDK.podspec`.
    public static let current = "2.1.13"

    /// Library identifier sent as `context.library`. Server-side platform
    /// detection keys on this exact string (`detectSource` in the ingest
    /// worker maps `@datalyr/swift` → `source: 'mobile_app'`), so it must not
    /// change without a coordinated server change.
    public static let libraryName = "@datalyr/swift"

    /// `User-Agent` header value, e.g. `@datalyr/swift/2.1.11`.
    public static var userAgent: String { "\(libraryName)/\(current)" }
}
