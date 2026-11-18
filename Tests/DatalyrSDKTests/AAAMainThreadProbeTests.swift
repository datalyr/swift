// TEMPORARY CI diagnostics (branch ci/main-thread-timing): which identity-path step waits
// for the main thread on the CI iOS Simulator. Not for merge.
import XCTest
@testable import DatalyrSDK
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

final class AAAMainThreadProbeTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    private func drainMain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }

    /// Hold main for up to `hold` seconds, run `body` off main, report how long it took.
    private func probe(_ name: String, hold: Double = 1.5, _ body: @escaping @Sendable () async -> Void) async {
        let blocker = DispatchSemaphore(value: 0)
        let blocked = Flag()
        DispatchQueue.main.async {
            blocked.value = true
            _ = blocker.wait(timeout: .now() + hold)
        }
        while !blocked.value { try? await Task.sleep(nanoseconds: 2_000_000) }
        let t0 = Date()
        await Task.detached { await body() }.value
        let dt = Date().timeIntervalSince(t0)
        blocker.signal()
        await drainMain()
        let tag = dt > hold * 0.8 ? " WAITED_ON_MAIN" : ""
        print("PROBE \(name) \(String(format: "%.3f", dt))s\(tag)")
    }

    func testProbePrimitives() async {
        print("PROBE isMainThread-at-start=\(Thread.isMainThread)")
        for round in 1...2 {
            #if canImport(UIKit)
            await probe("r\(round) UIDevice.current") { _ = UIDevice.current }
            await probe("r\(round) UIDevice.systemVersion") { _ = UIDevice.current.systemVersion }
            await probe("r\(round) UIDevice.identifierForVendor") { _ = UIDevice.current.identifierForVendor }
            await probe("r\(round) UIScreen.main") { _ = UIScreen.main }
            await probe("r\(round) UIScreen.main.bounds") { _ = UIScreen.main.bounds }
            await probe("r\(round) UIScreen.main.scale") { _ = UIScreen.main.scale }
            #endif
            await probe("r\(round) getDeviceModelName") { _ = getDeviceModelName() }
            await probe("r\(round) getDeviceInfo") { _ = getDeviceInfo() }
            await probe("r\(round) getOrCreateDeviceId") { _ = await getOrCreateDeviceId() }
            await probe("r\(round) Locale/TimeZone/country") {
                _ = Locale.current.identifier; _ = TimeZone.current.identifier; _ = currentCountryCode()
                _ = Locale.preferredLanguages.first
            }
            #if canImport(AppTrackingTransparency)
            await probe("r\(round) ATTrackingManager.status") {
                _ = PlatformIntegrationManager.liveTrackingAuthorizationStatus()
            }
            #endif
            #if canImport(AdSupport)
            await probe("r\(round) ASIdentifierManager.advertisingIdentifier") {
                _ = ASIdentifierManager.shared().advertisingIdentifier
            }
            #endif
            await probe("r\(round) UserDefaults set/get") {
                UserDefaults.standard.set("x", forKey: "probe_key")
                _ = UserDefaults.standard.string(forKey: "probe_key")
            }
            await probe("r\(round) UnifiedAttributionTracker.resetConversionState") {
                UnifiedAttributionTracker.shared.resetConversionState()
            }
        }
    }

    func testProbeSDKCalls() async {
        let manager = AttributionManager()
        await manager.initialize()
        let platform = PlatformIntegrationManager()
        platform.attStatusProvider = { 3 }
        let sdk = DatalyrSDK()
        sdk.configureForDeferredLookupTesting(
            config: DatalyrConfig(apiKey: "dk_test"),
            attributionManager: manager,
            platformIntegrationManager: platform
        )
        await sdk.loadIdentityForTesting()
        sdk.syncRevenueCatAttributes { _ in }
        sdk.syncSuperwallAttributes { _ in }
        await drainMain()

        for round in 1...2 {
            await probe("r\(round) sdk.track") { await sdk.track("probe_event") }
            await probe("r\(round) sdk.identify A") { await sdk.identify("probe-A-\(round)") }
            await probe("r\(round) sdk.identify B") { await sdk.identify("probe-B-\(round)") }
            await probe("r\(round) sdk.reset") { await sdk.reset() }
            await probe("r\(round) sdk.bindProviderIdentity") {
                await sdk.bindProviderIdentity(namespace: "superwall", providerUserId: "sw-\(round)")
            }
            await probe("r\(round) sdk.updateTrackingAuthorization") {
                await sdk.updateTrackingAuthorization(status: 3)
            }
        }
        await sdk.reset()
        await drainMain()
    }
}
