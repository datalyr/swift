import Foundation
#if canImport(UIKit)
import UIKit
#endif
import AdSupport
import AppTrackingTransparency

// MARK: - Logging Utilities

/// Debug logging function
internal func debugLog(_ message: String, data: Any? = nil) {
    if DatalyrSDK.shared.config?.debug == true {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        var logMessage = "[\(timestamp)] [Datalyr] \(message)"
        
        if let data = data {
            logMessage += " - \(data)"
        }
        
        print(logMessage)
    }
}

/// Error logging function
internal func errorLog(_ message: String, error: Error? = nil) {
    let timestamp = DateFormatter.logFormatter.string(from: Date())
    var logMessage = "[\(timestamp)] [Datalyr ERROR] \(message)"
    
    if let error = error {
        logMessage += " - \(error.localizedDescription)"
    }
    
    print(logMessage)
}

// MARK: - Validation Utilities

/// Normalize an event name for cross-SDK parity (mirrors the RN/web fleet's `normalizeEventName`,
/// TR-20a): trim, then collapse any run of whitespace to a single underscore, so
/// `track("Order Completed")` records as `Order_Completed` on iOS too instead of being silently
/// dropped by `validateEventName`. `$`-prefixed system names and dot/hyphen names are untouched.
internal func normalizeEventName(_ eventName: String) -> String {
    let trimmed = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
    // Collapse runs of whitespace → single underscore (matches RN's /\s+/g → '_').
    let collapsed = trimmed
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: "_")
    if collapsed != eventName {
        debugLog("Event name \"\(eventName)\" normalized to \"\(collapsed)\" (spaces → underscores)")
    }
    return collapsed
}

/// Validate event name
internal func validateEventName(_ eventName: String) -> Bool {
    // Event name must not be empty and should be reasonable length
    guard !eventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
    }
    
    guard eventName.count <= 100 else {
        return false
    }
    
    // Check for valid characters (alphanumeric, underscore, hyphen, dot, $ for internal events)
    let validCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.$"))
    return eventName.rangeOfCharacter(from: validCharacterSet.inverted) == nil
}

/// Validate event data
internal func validateEventData(_ eventData: EventData?) -> Bool {
    guard let eventData = eventData else { return true }

    // FSR-1: JSONSerialization.data(withJSONObject:) raises an *Objective-C*
    // NSInvalidArgumentException — NOT a Swift error — for non-JSON values like
    // Date/URL/UUID. A do/catch cannot catch that, so calling it on the raw caller
    // dict crashes the HOST APP (e.g. track("x", eventData: ["d": Date()])).
    // Guard with isValidJSONObject first; if the raw dict isn't JSON-safe, the SDK
    // still SUPPORTS these types (AnyCodable encodes Date→ISO8601 / URL→absoluteString /
    // NSNumber), so sanitize to a JSON-safe shape and size-check THAT rather than
    // rejecting valid input or letting the exception escape.
    let jsonSafe: [String: Any] = JSONSerialization.isValidJSONObject(eventData)
        ? eventData
        : sanitizeForJSONObject(eventData)

    // If sanitization still couldn't produce a serializable object (extremely
    // unusual), skip the size check instead of crashing — never throw to the caller.
    guard JSONSerialization.isValidJSONObject(jsonSafe) else {
        debugLog("Event data not JSON-serializable after sanitization; skipping size check")
        return true
    }

    // Check data size (approximate)
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: jsonSafe)
        // Limit to 32KB per event
        guard jsonData.count <= 32 * 1024 else {
            errorLog("Event data too large: \(jsonData.count) bytes (max 32KB)")
            return false
        }
    } catch {
        errorLog("Invalid event data JSON", error: error)
        return false
    }

    return true
}

/// Convert a `[String: Any]` containing SDK-supported-but-not-JSON-native types
/// (Date, URL, UUID, NSNumber, nested collections) into a JSON-serializable
/// dictionary. Mirrors AnyCodable's encoding (Date→ISO8601, URL→absoluteString) so
/// the value-shape matches what actually ships on the wire. Used to keep
/// JSONSerialization.data(withJSONObject:) from raising an uncatchable NSException
/// (FSR-1). Values that can't be represented are dropped rather than crashing.
internal func sanitizeForJSONObject(_ dict: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in dict {
        if let sanitized = sanitizeJSONValue(value) {
            result[key] = sanitized
        }
    }
    return result
}

private func sanitizeJSONValue(_ value: Any) -> Any? {
    // Unwrap AnyCodable
    if let anyCodable = value as? AnyCodable {
        return sanitizeJSONValue(anyCodable.value)
    }
    // JSON-native primitives pass through unchanged.
    if value is String || value is Bool { return value }
    if let v = value as? Int { return v }
    if let v = value as? Double { return v }
    if let v = value as? Float { return Double(v) }
    if let v = value as? UInt { return Int(exactly: v) ?? Int(v & UInt(Int.max)) }
    // NSNumber (covers JSON-decoded numbers and bridged Int/Double) — keep numeric.
    if let v = value as? NSNumber { return v }
    // SDK-supported non-JSON types → their wire representation.
    if let date = value as? Date { return DateFormatter.iso8601.string(from: date) }
    if let url = value as? URL { return url.absoluteString }
    if let uuid = value as? UUID { return uuid.uuidString }
    // Collections — recurse.
    if let nested = value as? [String: Any] { return sanitizeForJSONObject(nested) }
    if let arr = value as? [Any] { return arr.compactMap { sanitizeJSONValue($0) } }
    // Null / optional-nil → drop.
    if value is NSNull { return nil }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional && mirror.children.isEmpty { return nil }
    // Last resort — string-ify so the size check still sees something representative.
    let str = "\(value)"
    if str == "nil" || str == "Optional(nil)" { return nil }
    return str
}

// MARK: - Device Information

/// Get comprehensive device information
internal func getDeviceInfo() -> DeviceInfo {
    let locale = Locale.current
    let timeZone = TimeZone.current
    
    // Get device model name
    let deviceModel = getDeviceModelName()
    
    // Get device-specific information
    #if canImport(UIKit)
    let device = UIDevice.current
    let screen = UIScreen.main
    let osVersion = device.systemVersion
    let screenSize = "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))"
    #else
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let screenSize = "unknown"
    #endif
    
    // Check if running on simulator
    let isSimulator = isRunningOnSimulator()
    
    return DeviceInfo(
        model: deviceModel,
        manufacturer: "Apple",
        osVersion: osVersion,
        screenSize: screenSize,
        timezone: timeZone.identifier,
        locale: locale.identifier,
        carrier: getCarrierName(),
        isEmulator: isSimulator
    )
}

/// Cached device model name — computed once since it never changes at runtime
private var cachedDeviceModelName: String?

/// Get device model name (iPhone 14 Pro, iPad Air, etc.)
internal func getDeviceModelName() -> String {
    if let cached = cachedDeviceModelName {
        return cached
    }

    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    let identifier = machineMirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value)))
    }

    // Map hardware identifiers to human-readable names
    let result = mapDeviceIdentifier(identifier)
    cachedDeviceModelName = result
    return result
}

/// Map device identifier to human-readable name
private func mapDeviceIdentifier(_ identifier: String) -> String {
    switch identifier {
    // iPhone models
    case "iPhone14,7": return "iPhone 14"
    case "iPhone14,8": return "iPhone 14 Plus"
    case "iPhone15,2": return "iPhone 14 Pro"
    case "iPhone15,3": return "iPhone 14 Pro Max"
    case "iPhone15,4": return "iPhone 15"
    case "iPhone15,5": return "iPhone 15 Plus"
    case "iPhone16,1": return "iPhone 15 Pro"
    case "iPhone16,2": return "iPhone 15 Pro Max"
    case "iPhone13,1": return "iPhone 12 mini"
    case "iPhone13,2": return "iPhone 12"
    case "iPhone13,3": return "iPhone 12 Pro"
    case "iPhone13,4": return "iPhone 12 Pro Max"
    case "iPhone12,1": return "iPhone 11"
    case "iPhone12,3": return "iPhone 11 Pro"
    case "iPhone12,5": return "iPhone 11 Pro Max"
    
    // iPad models
    case "iPad13,18", "iPad13,19": return "iPad Pro 12.9-inch (6th generation)"
    case "iPad13,16", "iPad13,17": return "iPad Pro 11-inch (4th generation)"
    case "iPad14,3", "iPad14,4": return "iPad Pro 11-inch (4th generation)"
    case "iPad13,1", "iPad13,2": return "iPad Air (5th generation)"
    case "iPad12,1", "iPad12,2": return "iPad (9th generation)"
    
    default:
        // If we don't have a mapping, return the identifier
        return identifier
    }
}

/// Check if running on simulator
private func isRunningOnSimulator() -> Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}

/// Get carrier name
internal func getCarrierName() -> String? {
    // Note: CTTelephonyNetworkInfo is deprecated in iOS 16+
    // For privacy reasons, carrier information is limited
    return nil
}

/// Current ISO-3166-1 alpha-2 country code derived from device locale.
///
/// Server webhooks (Superwall/RevenueCat) have NULL geo on their own row; only
/// the matched web visitor's lander pageview carries geo via the bridge. For
/// users who skip a web prelander entirely, device locale is the only
/// zero-config country signal. meta.js USER_DATA_PATHS.country picks up
/// top-level `country` and hashes it for CAPI's `country` match key.
///
/// Prefers Locale.region.identifier (iOS 16+); falls back to parsing
/// Locale.current.identifier ("en_US" → "US") for older OS versions. Returns
/// nil for locales without a region tag (e.g. plain "en").
internal func currentCountryCode() -> String? {
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
        if let region = Locale.current.region?.identifier, region.count == 2 {
            return region.uppercased()
        }
    }
    // Fallback: identifier is "<language>_<REGION>[@calendar=...]"
    let id = Locale.current.identifier
    let beforeAt = id.split(separator: "@").first.map(String.init) ?? id
    let parts = beforeAt.split { $0 == "_" || $0 == "-" }
    guard parts.count >= 2 else { return nil }
    let region = String(parts[1]).uppercased()
    return region.count == 2 && region.allSatisfy({ $0.isLetter }) ? region : nil
}

// MARK: - Device Context

/// Create device context data
internal func createDeviceContext() async -> DeviceContext {
    let deviceId = await getOrCreateDeviceId()
    let deviceInfo = getDeviceInfo()

    return DeviceContext(
        deviceId: deviceId,
        deviceInfo: deviceInfo
    )
}

/// Get or create persistent device ID
internal func getOrCreateDeviceId() async -> String {
    let key = "datalyr_device_id"
    
    if let existingId = await DatalyrStorage.shared.getString(key) {
        return existingId
    }
    
    let newId = generateUUID()
    await DatalyrStorage.shared.setString(key, value: newId)
    return newId
}



// MARK: - ID Generation

/// Generate UUID string
internal func generateUUID() -> String {
    return UUID().uuidString
}

/// Get or create visitor ID
internal func getOrCreateVisitorId() async -> String {
    let key = "datalyr_visitor_id"
    
    if let existingId = await DatalyrStorage.shared.getString(key) {
        return existingId
    }
    
    let newId = generateUUID()
    await DatalyrStorage.shared.setString(key, value: newId)
    return newId
}

/// Get or create anonymous ID (persistent identity across app reinstalls)
internal func getOrCreateAnonymousId() async -> String {
    let key = "datalyr_anonymous_id"
    
    if let existingId = await DatalyrStorage.shared.getString(key) {
        return existingId
    }
    
    // Generate anonymous_id with anon_ prefix to match web SDK
    let newId = "anon_\(generateUUID())"
    await DatalyrStorage.shared.setString(key, value: newId)
    return newId
}

/// Get or create session ID
internal func getOrCreateSessionId() async -> String {
    let key = "datalyr_session_id"
    let timestampKey = "datalyr_session_timestamp"
    let sessionTimeout: TimeInterval = 30 * 60 // 30 minutes
    
    let now = Date().timeIntervalSince1970
    
    if let existingId = await DatalyrStorage.shared.getString(key),
       let lastTimestamp = await DatalyrStorage.shared.getDouble(timestampKey) {
        
        // Check if session is still valid
        if now - lastTimestamp < sessionTimeout {
            // Update timestamp
            await DatalyrStorage.shared.setDouble(timestampKey, value: now)
            return existingId
        }
    }
    
    // Create new session
    let newId = generateUUID()
    await DatalyrStorage.shared.setString(key, value: newId)
    await DatalyrStorage.shared.setDouble(timestampKey, value: now)
    return newId
}

/// Refresh session ID (for new sessions)
internal func refreshSessionId() async -> String {
    let key = "datalyr_session_id"
    let timestampKey = "datalyr_session_timestamp"
    
    let newId = generateUUID()
    let now = Date().timeIntervalSince1970
    
    await DatalyrStorage.shared.setString(key, value: newId)
    await DatalyrStorage.shared.setDouble(timestampKey, value: now)
    
    return newId
}

// MARK: - Network Type

/// Get current network type
internal func getNetworkType() -> String {
    // This would require additional permissions and frameworks
    // For now, return "unknown"
    return "unknown"
}

// MARK: - App Information

/// Get app version
internal func getAppVersion() -> String {
    return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
}

/// Get app build number
internal func getAppBuildNumber() -> String {
    return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
}

/// Get bundle identifier
internal func getBundleId() -> String {
    return Bundle.main.bundleIdentifier ?? "unknown"
}

// MARK: - Date Formatters

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        // Pin POSIX locale + Gregorian calendar so the year/format stay stable on
        // devices set to a non-Gregorian calendar (Buddhist/Japanese-era/Persian),
        // which otherwise emit e.g. 2569 instead of 2026 on every timestamp.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()
}

// MARK: - Storage Keys

internal enum StorageKeys {
    static let visitorId = "datalyr_visitor_id"
    static let anonymousId = "datalyr_anonymous_id"  // Persistent anonymous identifier
    static let sessionId = "datalyr_session_id"
    static let sessionTimestamp = "datalyr_session_timestamp"
    static let deviceId = "datalyr_device_id"
    static let userId = "datalyr_user_id"
    static let userProperties = "datalyr_user_properties"
    static let eventQueue = "datalyr_event_queue"
    static let deadLetterQueue = "datalyr_dead_letter_queue"
    static let attributionData = "datalyr_attribution_data"
    static let firstLaunchTime = "datalyr_first_launch_time"
    static let installTracked = "datalyr_install_tracked"
    static let lastAppVersion = "datalyr_last_app_version"
} 