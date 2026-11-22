import XCTest
@testable import DatalyrSDK

#if os(iOS)
/// C5: the public AdAttributionKitBridge shares the SDK's persisted high-water guard, so a
/// conversion value sent through it can never go down.
final class AdAttributionKitBridgeGuardTests: XCTestCase {

    private final class Sent {
        private let lock = NSLock()
        private var _values: [Int] = []
        func append(_ v: Int) { lock.withLock { _values.append(v) } }
        var values: [Int] { lock.withLock { _values } }
    }

    private let bridge = AdAttributionKitBridge.shared
    private let tracker = UnifiedAttributionTracker.shared
    private var sent = Sent()

    override func setUp() {
        super.setUp()
        tracker.resetConversionState()
        tracker.resetRegistrationForTest()
        sent = Sent()
        let sent = self.sent
        bridge.postbackSenderForTesting = { fine, _, _ in sent.append(fine) }
        bridge.legacySenderForTesting = { sent.append($0) }
    }

    override func tearDown() {
        bridge.postbackSenderForTesting = nil
        bridge.legacySenderForTesting = nil
        tracker.resetConversionState()
        tracker.resetRegistrationForTest()
        super.tearDown()
    }

    func testALowerValueAfterAHigherOneIsNotSent() async throws {
        try await bridge.updatePostbackConversionValue(fineValue: 32, coarseValue: .medium, lockWindow: false)
        try await bridge.updatePostbackConversionValue(fineValue: 8, coarseValue: .low, lockWindow: false)
        try await bridge.updatePostbackConversionValue(fineValue: 32, coarseValue: .low, lockWindow: false)
        XCTAssertEqual(sent.values, [32])

        try await bridge.updatePostbackConversionValue(fineValue: 32, coarseValue: .high, lockWindow: false)
        try await bridge.updatePostbackConversionValue(fineValue: 40, coarseValue: .high, lockWindow: true)
        try await bridge.updatePostbackConversionValue(fineValue: 63, coarseValue: .high, lockWindow: false)
        XCTAssertEqual(sent.values, [32, 32, 40], "equal fine + higher coarse goes; nothing after a locked window")
    }

    func testTheBridgeAndTheSDKShareOneHighWater() async throws {
        // The SDK's own tracker recorded 40; the bridge must not send 20 after it...
        XCTAssertTrue(tracker.applyHighWaterForTest(fineValue: 40, coarseValue: "medium", lockWindow: false))
        try await bridge.updatePostbackConversionValue(fineValue: 20, coarseValue: .high, lockWindow: false)
        XCTAssertEqual(sent.values, [])
        // ...and what the bridge sends raises it for the tracker too.
        try await bridge.updatePostbackConversionValue(fineValue: 50, coarseValue: .low, lockWindow: false)
        XCTAssertEqual(sent.values, [50])
        XCTAssertFalse(tracker.wouldRaiseHighWater(fineValue: 45, coarseValue: "high"))
    }

    func testLegacyUpdateIsGuardedToo() throws {
        guard #available(iOS 14.0, *) else { throw XCTSkip("legacy SKAdNetwork API is iOS 14+") }
        bridge.updateConversionValue(30)
        bridge.updateConversionValue(10)
        bridge.updateConversionValue(30)
        bridge.updateConversionValue(31)
        XCTAssertEqual(sent.values, [30, 31])
    }

    func testAFailedSendDoesNotRaiseTheHighWater() async {
        bridge.postbackSenderForTesting = { _, _, _ in throw NSError(domain: "SKAdNetwork", code: 1) }
        do {
            try await bridge.updatePostbackConversionValue(fineValue: 40, coarseValue: .high, lockWindow: false)
            XCTFail("the OS error is still thrown")
        } catch {}
        XCTAssertTrue(tracker.wouldRaiseHighWater(fineValue: 40, coarseValue: "high"), "a retry may still send 40")
    }

    func testOutOfRangeStillThrows() async {
        do {
            try await bridge.updatePostbackConversionValue(fineValue: 64, coarseValue: .high, lockWindow: false)
            XCTFail("expected invalidConversionValue")
        } catch AttributionError.invalidConversionValue {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRegistrationNeverLowersASentValue() async throws {
        guard #available(iOS 17.4, *) else { throw XCTSkip("0-value registration is iOS 17.4+") }
        try await bridge.registerForAttribution()
        try await bridge.registerForAttribution()
        XCTAssertEqual(sent.values, [0], "the 0/low registration goes once per install")

        tracker.resetRegistrationForTest()
        try await bridge.updatePostbackConversionValue(fineValue: 12, coarseValue: .low, lockWindow: false)
        try await bridge.registerForAttribution()
        XCTAssertEqual(sent.values, [0, 12], "no 0/low after a higher value")
    }
}
#endif
