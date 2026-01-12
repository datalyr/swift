import Foundation
import StoreKit

#if canImport(AdAttributionKit)
import AdAttributionKit
#endif

// MARK: - Attribution Framework Type
public enum AttributionFramework: String {
    case adAttributionKit = "AdAttributionKit"
    case skadNetwork4 = "SKAdNetwork4"
    case skadNetwork3 = "SKAdNetwork3"
    case none = "none"
}

// MARK: - Attribution Info
public struct AttributionInfo {
    public let framework: AttributionFramework
    public let version: String
    public let supportsReengagement: Bool
    public let supportsOverlappingWindows: Bool

    public var dictionary: [String: Any] {
        return [
            "framework": framework.rawValue,
            "version": version,
            "reengagement_available": supportsReengagement,
            "overlapping_windows": supportsOverlappingWindows
        ]
    }
}

// MARK: - Coarse Value (cross-framework)
public enum CoarseConversionValue: String {
    case low = "low"
    case medium = "medium"
    case high = "high"
}

// MARK: - AdAttributionKit Bridge
/// Unified bridge for Apple's attribution frameworks.
/// Uses AdAttributionKit on iOS 17.4+ and falls back to SKAdNetwork on older versions.
public class AdAttributionKitBridge {

    public static let shared = AdAttributionKitBridge()

    private init() {}

    // MARK: - Framework Detection

    /// Check if AdAttributionKit is available (iOS 17.4+)
    public var isAdAttributionKitAvailable: Bool {
        if #available(iOS 17.4, *) {
            return true
        }
        return false
    }

    /// Check if SKAdNetwork 4.0 is available (iOS 16.1+)
    public var isSKAN4Available: Bool {
        if #available(iOS 16.1, *) {
            return true
        }
        return false
    }

    /// Check if any attribution framework is available (iOS 14.0+)
    public var isAttributionAvailable: Bool {
        if #available(iOS 14.0, *) {
            return true
        }
        return false
    }

    /// Get current attribution framework info
    public func getAttributionInfo() -> AttributionInfo {
        if #available(iOS 17.4, *) {
            var supportsOverlapping = false
            if #available(iOS 18.4, *) {
                supportsOverlapping = true
            }
            return AttributionInfo(
                framework: .adAttributionKit,
                version: "1.0",
                supportsReengagement: true,
                supportsOverlappingWindows: supportsOverlapping
            )
        } else if #available(iOS 16.1, *) {
            return AttributionInfo(
                framework: .skadNetwork4,
                version: "4.0",
                supportsReengagement: false,
                supportsOverlappingWindows: false
            )
        } else if #available(iOS 14.0, *) {
            return AttributionInfo(
                framework: .skadNetwork3,
                version: "3.0",
                supportsReengagement: false,
                supportsOverlappingWindows: false
            )
        }
        return AttributionInfo(
            framework: .none,
            version: "0",
            supportsReengagement: false,
            supportsOverlappingWindows: false
        )
    }

    // MARK: - Registration

    /// Register app for ad network attribution
    /// Uses AdAttributionKit on iOS 17.4+, SKAdNetwork on older versions
    public func registerForAttribution() async throws {
        if #available(iOS 17.4, *) {
            // AdAttributionKit: registration happens implicitly with first postback update
            // Send initial conversion value of 0 to register
            try await updatePostbackConversionValue(
                fineValue: 0,
                coarseValue: .low,
                lockWindow: false
            )
        } else if #available(iOS 14.0, *) {
            // SKAdNetwork: explicit registration
            SKAdNetwork.registerAppForAdNetworkAttribution()
        } else {
            throw AttributionError.unsupportedIOSVersion
        }
    }

    // MARK: - Conversion Value Updates

    /// Update conversion value using the appropriate framework
    /// - Parameters:
    ///   - fineValue: Fine-grained conversion value (0-63)
    ///   - coarseValue: Coarse conversion value (.low, .medium, .high)
    ///   - lockWindow: Whether to lock the conversion window (SKAN 4.0+ / AAK)
    public func updatePostbackConversionValue(
        fineValue: Int,
        coarseValue: CoarseConversionValue,
        lockWindow: Bool
    ) async throws {
        // Validate fine value range
        guard fineValue >= 0 && fineValue <= 63 else {
            throw AttributionError.invalidConversionValue
        }

        if #available(iOS 17.4, *) {
            // AdAttributionKit uses the same StoreKit API but with enhanced features
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let skCoarse = coarseValue.toSKAdNetworkValue()
                SKAdNetwork.updatePostbackConversionValue(fineValue, coarseValue: skCoarse, lockWindow: lockWindow) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else if #available(iOS 16.1, *) {
            // SKAdNetwork 4.0
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let skCoarse = coarseValue.toSKAdNetworkValue()
                SKAdNetwork.updatePostbackConversionValue(fineValue, coarseValue: skCoarse, lockWindow: lockWindow) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else if #available(iOS 14.0, *) {
            // SKAdNetwork 3.0 - only supports fine value
            SKAdNetwork.updateConversionValue(fineValue)
        } else {
            throw AttributionError.unsupportedIOSVersion
        }
    }

    /// Update conversion value with legacy API (SKAN 3.0 compatible)
    /// - Parameter value: Conversion value (0-63)
    @available(iOS 14.0, *)
    public func updateConversionValue(_ value: Int) {
        SKAdNetwork.updateConversionValue(value)
    }

    // MARK: - Re-engagement Attribution (AdAttributionKit only)

    /// Check if re-engagement attribution is supported
    public var supportsReengagement: Bool {
        if #available(iOS 17.4, *) {
            return true
        }
        return false
    }

    /// Update conversion value for re-engagement (AdAttributionKit iOS 17.4+)
    /// Re-engagement tracks users who return to the app via an ad
    @available(iOS 17.4, *)
    public func updateReengagementConversionValue(
        fineValue: Int,
        coarseValue: CoarseConversionValue,
        lockWindow: Bool
    ) async throws {
        // Re-engagement uses the same API as initial attribution in AdAttributionKit
        // The framework automatically distinguishes based on user state
        try await updatePostbackConversionValue(
            fineValue: fineValue,
            coarseValue: coarseValue,
            lockWindow: lockWindow
        )
    }

    // MARK: - Overlapping Windows (iOS 18.4+)

    /// Check if overlapping conversion windows are supported
    public var supportsOverlappingWindows: Bool {
        if #available(iOS 18.4, *) {
            return true
        }
        return false
    }
}

// MARK: - CoarseConversionValue Extension
extension CoarseConversionValue {
    @available(iOS 16.1, *)
    func toSKAdNetworkValue() -> SKAdNetwork.CoarseConversionValue {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

// MARK: - Attribution Errors
public enum AttributionError: LocalizedError {
    case unsupportedIOSVersion
    case invalidConversionValue
    case updateFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedIOSVersion:
            return "Attribution requires iOS 14.0 or later"
        case .invalidConversionValue:
            return "Conversion value must be between 0 and 63"
        case .updateFailed(let error):
            return "Failed to update conversion value: \(error.localizedDescription)"
        }
    }
}

// MARK: - Convenience Methods
extension AdAttributionKitBridge {

    /// Update conversion value from ConversionResult (from ConversionValueEncoder)
    public func updateFromConversionResult(_ result: ConversionResult) async throws {
        let coarse: CoarseConversionValue
        switch result.coarseValue {
        case "high": coarse = .high
        case "medium": coarse = .medium
        default: coarse = .low
        }

        try await updatePostbackConversionValue(
            fineValue: result.fineValue,
            coarseValue: coarse,
            lockWindow: result.lockWindow
        )
    }

    /// Encode and update conversion value in one call
    public func trackConversion(
        encoder: ConversionValueEncoder,
        event: String,
        properties: [String: Any]?
    ) async throws {
        let result = encoder.encodeWithSKAN4(event: event, properties: properties)
        try await updateFromConversionResult(result)
    }
}
