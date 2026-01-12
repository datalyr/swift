import Foundation
import StoreKit

// MARK: - AdAttributionKit Integration (iOS 17.4+)

/// AdAttributionKit integration for iOS 17.4+
/// This is Apple's replacement for SKAdNetwork with enhanced features:
/// - Re-engagement attribution
/// - Overlapping conversion windows (iOS 18.4+)
/// - Configurable attribution windows
/// - Geography data in postbacks
@available(iOS 17.4, *)
internal class AdAttributionKitIntegration {
    static let shared = AdAttributionKitIntegration()

    private var isRegistered = false
    private var currentFineValue: Int = 0
    private var currentCoarseValue: CoarseValue = .low
    private var conversionWindowLocked = false

    // Track postback windows for SKAN 4.0+ style multi-postback support
    private var postbackWindowStates: [PostbackWindowState] = []

    private init() {}

    // MARK: - Coarse Value Enum

    enum CoarseValue: String {
        case low = "low"
        case medium = "medium"
        case high = "high"

        @available(iOS 17.4, *)
        var systemValue: SKAdNetwork.CoarseConversionValue {
            switch self {
            case .low: return .low
            case .medium: return .medium
            case .high: return .high
            }
        }

        static func from(_ value: String) -> CoarseValue {
            switch value.lowercased() {
            case "high": return .high
            case "medium": return .medium
            default: return .low
            }
        }
    }

    // MARK: - Postback Window Tracking

    struct PostbackWindowState {
        let windowIndex: Int  // 0 = 0-2 days, 1 = 3-7 days, 2 = 8-35 days
        var fineValue: Int
        var coarseValue: CoarseValue
        var isLocked: Bool
        let startTime: Date
        let endTime: Date
    }

    // MARK: - Public Methods

    /// Register app for ad network attribution
    /// Should be called once at app launch
    func registerAppForAttribution() async {
        guard !isRegistered else { return }

        if #available(iOS 17.4, *) {
            do {
                // Register for both install and re-engagement attribution
                SKAdNetwork.updatePostbackConversionValue(0, coarseValue: .low, lockWindow: false) { error in
                    if let error = error {
                        errorLog("Failed to register for AdAttributionKit: \(error.localizedDescription)")
                    } else {
                        debugLog("AdAttributionKit: Registered for attribution")
                    }
                }
                isRegistered = true
                initializePostbackWindows()
            }
        } else {
            debugLog("AdAttributionKit: Not available (requires iOS 17.4+)")
        }
    }

    /// Update conversion value with AdAttributionKit
    /// - Parameters:
    ///   - fineValue: Fine-grained value 0-63
    ///   - coarseValue: Coarse value (low/medium/high)
    ///   - lockWindow: Whether to lock the current conversion window
    func updateConversionValue(fineValue: Int, coarseValue: CoarseValue, lockWindow: Bool) async -> Bool {
        guard #available(iOS 17.4, *) else {
            debugLog("AdAttributionKit: Not available (requires iOS 17.4+)")
            return false
        }

        // Don't update if window is already locked
        guard !conversionWindowLocked else {
            debugLog("AdAttributionKit: Conversion window is locked, skipping update")
            return false
        }

        // Only update if new value is higher priority (higher fine value or coarse value)
        let shouldUpdate = shouldUpdateValue(newFine: fineValue, newCoarse: coarseValue)
        guard shouldUpdate else {
            debugLog("AdAttributionKit: Skipping update (current value is higher priority)")
            return false
        }

        return await withCheckedContinuation { continuation in
            SKAdNetwork.updatePostbackConversionValue(fineValue, coarseValue: coarseValue.systemValue, lockWindow: lockWindow) { [weak self] error in
                if let error = error {
                    errorLog("AdAttributionKit: Failed to update conversion value: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else {
                    self?.currentFineValue = fineValue
                    self?.currentCoarseValue = coarseValue
                    if lockWindow {
                        self?.conversionWindowLocked = true
                    }
                    debugLog("AdAttributionKit: Updated conversion value to \(fineValue) (\(coarseValue.rawValue)), locked: \(lockWindow)")
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// Track event and update conversion value based on template
    func trackEvent(_ eventName: String, properties: [String: Any]?, encoder: ConversionValueEncoder) async -> Bool {
        let result = encoder.encodeWithSKAN4(event: eventName, properties: properties)

        return await updateConversionValue(
            fineValue: result.fineValue,
            coarseValue: CoarseValue.from(result.coarseValue),
            lockWindow: result.lockWindow
        )
    }

    /// Check if AdAttributionKit is available
    var isAvailable: Bool {
        if #available(iOS 17.4, *) {
            return true
        }
        return false
    }

    /// Check if re-engagement tracking is available (iOS 17.4+)
    var isReengagementAvailable: Bool {
        if #available(iOS 17.4, *) {
            return true
        }
        return false
    }

    /// Check if overlapping windows are available (iOS 18.4+)
    var isOverlappingWindowsAvailable: Bool {
        if #available(iOS 18.4, *) {
            return true
        }
        return false
    }

    /// Get current conversion state
    func getConversionState() -> (fineValue: Int, coarseValue: String, isLocked: Bool) {
        return (currentFineValue, currentCoarseValue.rawValue, conversionWindowLocked)
    }

    /// Get current postback window index (0-2)
    func getCurrentPostbackWindow() -> Int {
        let now = Date()
        let installTime = postbackWindowStates.first?.startTime ?? now

        let daysSinceInstall = Calendar.current.dateComponents([.day], from: installTime, to: now).day ?? 0

        if daysSinceInstall <= 2 {
            return 0  // Window 0: 0-2 days
        } else if daysSinceInstall <= 7 {
            return 1  // Window 1: 3-7 days
        } else {
            return 2  // Window 2: 8-35 days
        }
    }

    // MARK: - Private Methods

    private func initializePostbackWindows() {
        let now = Date()
        let calendar = Calendar.current

        // Initialize the three postback windows
        postbackWindowStates = [
            PostbackWindowState(
                windowIndex: 0,
                fineValue: 0,
                coarseValue: .low,
                isLocked: false,
                startTime: now,
                endTime: calendar.date(byAdding: .day, value: 2, to: now) ?? now
            ),
            PostbackWindowState(
                windowIndex: 1,
                fineValue: 0,
                coarseValue: .low,
                isLocked: false,
                startTime: calendar.date(byAdding: .day, value: 3, to: now) ?? now,
                endTime: calendar.date(byAdding: .day, value: 7, to: now) ?? now
            ),
            PostbackWindowState(
                windowIndex: 2,
                fineValue: 0,
                coarseValue: .low,
                isLocked: false,
                startTime: calendar.date(byAdding: .day, value: 8, to: now) ?? now,
                endTime: calendar.date(byAdding: .day, value: 35, to: now) ?? now
            )
        ]

        debugLog("AdAttributionKit: Initialized postback windows")
    }

    private func shouldUpdateValue(newFine: Int, newCoarse: CoarseValue) -> Bool {
        // Always update if fine value is higher
        if newFine > currentFineValue {
            return true
        }

        // If fine values are equal, check coarse value
        if newFine == currentFineValue {
            let coarseOrder: [CoarseValue] = [.low, .medium, .high]
            let currentIndex = coarseOrder.firstIndex(of: currentCoarseValue) ?? 0
            let newIndex = coarseOrder.firstIndex(of: newCoarse) ?? 0
            return newIndex > currentIndex
        }

        return false
    }
}

// MARK: - Backward Compatibility Wrapper

/// Unified attribution tracking that uses AdAttributionKit on iOS 17.4+ and SKAdNetwork on earlier versions
internal class UnifiedAttributionTracker {
    static let shared = UnifiedAttributionTracker()

    private init() {}

    /// Register for attribution tracking
    func register() async {
        if #available(iOS 17.4, *) {
            await AdAttributionKitIntegration.shared.registerAppForAttribution()
        } else if #available(iOS 14.0, *) {
            // Legacy SKAdNetwork registration
            SKAdNetwork.registerAppForAdNetworkAttribution()
            debugLog("SKAdNetwork: Registered for attribution (legacy)")
        }
    }

    /// Update conversion value (automatically uses correct API based on iOS version)
    func updateConversionValue(fineValue: Int, coarseValue: String, lockWindow: Bool) async -> Bool {
        if #available(iOS 17.4, *) {
            return await AdAttributionKitIntegration.shared.updateConversionValue(
                fineValue: fineValue,
                coarseValue: AdAttributionKitIntegration.CoarseValue.from(coarseValue),
                lockWindow: lockWindow
            )
        } else if #available(iOS 16.1, *) {
            // SKAN 4.0
            return await withCheckedContinuation { continuation in
                let coarse: SKAdNetwork.CoarseConversionValue
                switch coarseValue.lowercased() {
                case "high": coarse = .high
                case "medium": coarse = .medium
                default: coarse = .low
                }

                SKAdNetwork.updatePostbackConversionValue(fineValue, coarseValue: coarse, lockWindow: lockWindow) { error in
                    if let error = error {
                        errorLog("SKAdNetwork 4.0: Failed to update: \(error.localizedDescription)")
                        continuation.resume(returning: false)
                    } else {
                        debugLog("SKAdNetwork 4.0: Updated to \(fineValue) (\(coarseValue))")
                        continuation.resume(returning: true)
                    }
                }
            }
        } else if #available(iOS 14.0, *) {
            // SKAN 3.0 (legacy)
            SKAdNetwork.updateConversionValue(fineValue)
            debugLog("SKAdNetwork 3.0: Updated to \(fineValue)")
            return true
        }

        return false
    }

    /// Get attribution framework info
    func getAttributionInfo() -> [String: Any] {
        var info: [String: Any] = [:]

        if #available(iOS 17.4, *) {
            info["framework"] = "AdAttributionKit"
            info["version"] = "1.0"
            info["reengagement_available"] = true
            info["overlapping_windows"] = {
                if #available(iOS 18.4, *) {
                    return true
                }
                return false
            }()
            let state = AdAttributionKitIntegration.shared.getConversionState()
            info["current_fine_value"] = state.fineValue
            info["current_coarse_value"] = state.coarseValue
            info["window_locked"] = state.isLocked
            info["current_window"] = AdAttributionKitIntegration.shared.getCurrentPostbackWindow()
        } else if #available(iOS 16.1, *) {
            info["framework"] = "SKAdNetwork"
            info["version"] = "4.0"
            info["reengagement_available"] = false
        } else if #available(iOS 14.0, *) {
            info["framework"] = "SKAdNetwork"
            info["version"] = "3.0"
            info["reengagement_available"] = false
        } else {
            info["framework"] = "none"
            info["version"] = "0"
        }

        return info
    }
}
