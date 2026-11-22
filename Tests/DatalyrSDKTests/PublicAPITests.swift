import XCTest
@testable import DatalyrSDK

/// Public entry points that had no tests: deprecated getters, configure(apiKey:),
/// trackPurchase and the global helper functions.
final class PublicAPITests: XCTestCase {

    // MARK: - W4: deprecated API keeps working

    @available(*, deprecated)
    func testDeprecatedGettersStillAnswerNil() {
        let sdk = DatalyrSDK()
        XCTAssertNil(sdk.getDeferredAttributionData())
        XCTAssertNil(sdk.getLastError())
    }

    @available(*, deprecated)
    func testDeprecatedConfigOptionsStillAccepted() {
        let auto = AutoEventConfig(trackAppUpdates: false, trackPerformance: true)
        let config = DatalyrConfig(apiKey: "dk_test", respectDoNotTrack: false, autoEventConfig: auto)
        XCTAssertFalse(config.respectDoNotTrack)
        XCTAssertFalse(auto.trackAppUpdates)
        XCTAssertTrue(auto.trackPerformance)
    }

    // MARK: - W18 / W14: configure(apiKey:) — one function, every old call form

    /// An empty key makes initialize throw before it touches any state, so these are
    /// real calls into the shared instance that leave it uninitialized.
    private func assertRejectsEmptyKey(_ call: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await call()
            XCTFail("expected invalidConfiguration", file: file, line: line)
        } catch DatalyrError.invalidConfiguration(_) {
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testConfigureAcceptsEveryOldCallForm() async {
        // Old overload 1: configure(apiKey:workspaceId:debug:)
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "") }
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", workspaceId: "ws") }
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", debug: true) }
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", workspaceId: "ws", debug: false) }
        // Old overload 2: + enableAutoEvents / enableAttribution
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", enableAutoEvents: false) }
        await assertRejectsEmptyKey { try await DatalyrSDK.configure(apiKey: "", enableAttribution: false) }
        await assertRejectsEmptyKey {
            try await DatalyrSDK.configure(apiKey: "", workspaceId: "ws", debug: false,
                                           enableAutoEvents: true, enableAttribution: false)
        }
        XCTAssertFalse(DatalyrSDK.shared.isInitialized)
    }

    func testConfigureBuildsTheSameConfigAsBothOldOverloads() {
        let basic = DatalyrSDK.configureConfig(apiKey: "dk_test", workspaceId: "ws", debug: true)
        XCTAssertEqual(basic.apiKey, "dk_test")
        XCTAssertEqual(basic.workspaceId, "ws")
        XCTAssertTrue(basic.debug)
        XCTAssertTrue(basic.enableAutoEvents)
        XCTAssertTrue(basic.enableAttribution)
        XCTAssertNil(basic.autoEventConfig, "nil reads as AutoEventConfig(), the defaults both overloads used")

        let full = DatalyrSDK.configureConfig(apiKey: "dk_test", enableAutoEvents: false, enableAttribution: false)
        XCTAssertFalse(full.enableAutoEvents)
        XCTAssertFalse(full.enableAttribution)
        XCTAssertFalse(full.debug)
        XCTAssertEqual(full.workspaceId, "")
        XCTAssertTrue(full.useServerTracking)
    }
}
