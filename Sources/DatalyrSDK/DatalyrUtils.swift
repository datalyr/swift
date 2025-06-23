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

/// Validate event name
internal func validateEventName(_ eventName: String) -> Bool {
    // Event name must not be empty and should be reasonable length
    guard !eventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
    }
    
    guard eventName.count <= 100 else {
        return false
    }
    
    // Check for valid characters (alphanumeric, underscore, hyphen, dot)
    let validCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
    return eventName.rangeOfCharacter(from: validCharacterSet.inverted) == nil
}

/// Validate event data
internal func validateEventData(_ eventData: EventData?) -> Bool {
    guard let eventData = eventData else { return true }
    
    // Check data size (approximate)
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: eventData)
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

// MARK: - Device Information

/// Get comprehensive device information
internal func getDeviceInfo() -> DeviceInfo {
    let device = UIDevice.current
    let screen = UIScreen.main
    let locale = Locale.current
    let timeZone = TimeZone.current
    
    // Get device model name
    let deviceModel = getDeviceModelName()
    
    // Get screen dimensions
    let screenSize = "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))"
    
    // Check if running on simulator
    let isSimulator = isRunningOnSimulator()
    
    return DeviceInfo(
        model: deviceModel,
        manufacturer: "Apple",
        osVersion: device.systemVersion,
        screenSize: screenSize,
        timezone: timeZone.identifier,
        locale: locale.identifier,
        carrier: getCarrierName(),
        isEmulator: isSimulator
    )
}

/// Get device model name (iPhone 14 Pro, iPad Air, etc.)
private func getDeviceModelName() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    let identifier = machineMirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value))!)
    }
    
    // Map hardware identifiers to human-readable names
    return mapDeviceIdentifier(identifier)
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
private func getCarrierName() -> String? {
    // Note: CTTelephonyNetworkInfo is deprecated in iOS 16+
    // For privacy reasons, carrier information is limited
    return nil
}

// MARK: - Fingerprint Data

/// Create device fingerprint data
internal func createFingerprintData() async -> FingerprintData {
    let deviceId = await getOrCreateDeviceId()
    let advertisingId = await getAdvertisingId()
    let deviceInfo = getDeviceInfo()
    
    return FingerprintData(
        deviceId: deviceId,
        advertisingId: advertisingId,
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

/// Get advertising ID (IDFA) with proper privacy handling
internal func getAdvertisingId() async -> String? {
    // Check iOS version and tracking authorization
    if #available(iOS 14, *) {
        let status = ATTrackingManager.trackingAuthorizationStatus
        
        switch status {
        case .authorized:
            let idfa = ASIdentifierManager.shared().advertisingIdentifier
            return idfa.uuidString != "00000000-0000-0000-0000-000000000000" ? idfa.uuidString : nil
        case .denied, .restricted:
            return nil
        case .notDetermined:
            // Request permission if not determined
            let requestedStatus = await ATTrackingManager.requestTrackingAuthorization()
            if requestedStatus == .authorized {
                let idfa = ASIdentifierManager.shared().advertisingIdentifier
                return idfa.uuidString != "00000000-0000-0000-0000-000000000000" ? idfa.uuidString : nil
            }
            return nil
        @unknown default:
            return nil
        }
    } else {
        // iOS 13 and earlier
        let idfa = ASIdentifierManager.shared().advertisingIdentifier
        return ASIdentifierManager.shared().isAdvertisingTrackingEnabled ? idfa.uuidString : nil
    }
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
        return formatter
    }()
}

// MARK: - Storage Keys

internal enum StorageKeys {
    static let visitorId = "datalyr_visitor_id"
    static let sessionId = "datalyr_session_id"
    static let sessionTimestamp = "datalyr_session_timestamp"
    static let deviceId = "datalyr_device_id"
    static let userId = "datalyr_user_id"
    static let userProperties = "datalyr_user_properties"
    static let eventQueue = "datalyr_event_queue"
    static let attributionData = "datalyr_attribution_data"
    static let firstLaunchTime = "datalyr_first_launch_time"
    static let installTracked = "datalyr_install_tracked"
    static let lastAppVersion = "datalyr_last_app_version"
} 