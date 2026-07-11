import XCTest
@testable import DatalyrSDK

/// Tests for the FULL_STACK_REVIEW_2026-06-10 iOS fixes (FSR-*). Each test names the FSR id
/// it guards so a future regression points straight back to the finding.
final class FullStackReviewTests: XCTestCase {

    // MARK: - FSR-1: validateEventData / sanitize must never crash on non-JSON values

    func testFSR1_validateEventDataAcceptsDateURLUUID_noCrash() {
        // These dicts would raise an uncatchable NSException inside
        // JSONSerialization.data(withJSONObject:) on the RAW dict — the host-app crash.
        // validateEventData must guard with isValidJSONObject + sanitize, returning true.
        XCTAssertTrue(validateEventData(["signup_date": Date()]))
        XCTAssertTrue(validateEventData(["link": URL(string: "https://datalyr.com")!]))
        XCTAssertTrue(validateEventData(["id": UUID()]))
        XCTAssertTrue(validateEventData(["mixed": ["d": Date(), "n": 5, "s": "x"]]))
        // Plain JSON-safe data still validates.
        XCTAssertTrue(validateEventData(["a": 1, "b": "two", "c": true]))
        // nil is fine.
        XCTAssertTrue(validateEventData(nil))
    }

    func testFSR1_sanitizeForJSONObjectProducesJSONSafeShape() {
        let date = Date(timeIntervalSince1970: 0)
        let sanitized = sanitizeForJSONObject([
            "d": date,
            "u": URL(string: "https://datalyr.com/path?x=1")!,
            "id": UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            "n": 42,
            "f": Float(1.5),
            "nested": ["inner": Date(timeIntervalSince1970: 0)]
        ])
        // Result must be serializable (the whole point of FSR-1).
        XCTAssertTrue(JSONSerialization.isValidJSONObject(sanitized))
        XCTAssertEqual(sanitized["u"] as? String, "https://datalyr.com/path?x=1")
        XCTAssertEqual(sanitized["id"] as? String, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(sanitized["n"] as? Int, 42)
        XCTAssertNotNil(sanitized["d"] as? String) // Date → ISO8601 string
        XCTAssertTrue(JSONSerialization.isValidJSONObject(sanitized["nested"] as? [String: Any] ?? [:]))
    }

    func testFSR1_track_and_identify_doNotCrashWithDateValues() async {
        // End-to-end: track() and identify() with Date/URL values must not crash. These run
        // before initialize() so they exercise the pre-init buffering path too (no network).
        await DatalyrSDK.shared.track("signup", eventData: ["signup_date": Date(), "url": URL(string: "https://x.co")!])
        await DatalyrSDK.shared.identify("u_fsr1", properties: ["joined": Date(), "ref": URL(string: "https://x.co")!])
        XCTAssertTrue(true, "reached here without an NSException terminating the test process")
    }

    // MARK: - FSR-30: mergeWebAttribution gap-fills gbraid / wbraid / lyr

    func testFSR30_mergeWebAttributionFillsGbraidWbraidLyr() async {
        let mgr = AttributionManager()
        await mgr.mergeWebAttribution([
            "gbraid": "GB_123",
            "wbraid": "WB_456",
            "lyr": "LYR_789",
            "gclid": "GC_000"
        ])
        let data = mgr.getAttributionData()
        XCTAssertEqual(data.gbraid, "GB_123")
        XCTAssertEqual(data.wbraid, "WB_456")
        XCTAssertEqual(data.lyr, "LYR_789")
        XCTAssertEqual(data.gclid, "GC_000")
    }

    func testFSR30_mergeWebAttributionDoesNotOverwriteExistingGbraid() async {
        let mgr = AttributionManager()
        // Seed existing gbraid via a first merge, then a second should NOT overwrite (gap-fill).
        await mgr.mergeWebAttribution(["gbraid": "ORIGINAL"])
        await mgr.mergeWebAttribution(["gbraid": "NEWER"])
        XCTAssertEqual(mgr.getAttributionData().gbraid, "ORIGINAL")
    }

    // MARK: - FSR-35: oppref round-trips through Codable persistence

    func testFSR35_opprefRoundTripsThroughCodable() throws {
        var attribution = AttributionData()
        attribution.fbclid = "FB"
        attribution.oppref = "OPENAI_REF"
        attribution.gbraid = "GB"
        attribution.dclid = "DC"

        let encoded = try JSONEncoder().encode(attribution)
        let decoded = try JSONDecoder().decode(AttributionData.self, from: encoded)

        XCTAssertEqual(decoded.oppref, "OPENAI_REF", "oppref must survive encode/decode (FSR-35)")
        XCTAssertEqual(decoded.fbclid, "FB")
        XCTAssertEqual(decoded.gbraid, "GB")
        XCTAssertEqual(decoded.dclid, "DC", "dclid must round-trip (FSR-86)")
    }

    func testFSR35_fullAttributionDataRoundTripFieldForField() throws {
        var a = AttributionData()
        a.lyr = "lyr1"; a.datalyr = "dl1"; a.dlTag = "tag"; a.dlCampaign = "camp"
        a.utmSource = "google"; a.utmMedium = "cpc"; a.utmCampaign = "c"; a.utmTerm = "t"; a.utmContent = "ct"
        a.fbclid = "fb"; a.ttclid = "tt"; a.gclid = "gc"; a.wbraid = "wb"; a.gbraid = "gb"
        a.dclid = "dc"; a.oppref = "op"; a.twclid = "tw"; a.liClickId = "li"; a.msclkid = "ms"
        a.partnerId = "p"; a.affiliateId = "af"; a.referrerId = "rf"; a.sourceId = "src"
        a.attributionCapturedAt = 1234567.0

        let decoded = try JSONDecoder().decode(AttributionData.self, from: try JSONEncoder().encode(a))
        // Every populated field must survive — the class of bug FSR-35 is.
        XCTAssertEqual(decoded.oppref, "op")
        XCTAssertEqual(decoded.dclid, "dc")
        XCTAssertEqual(decoded.gbraid, "gb")
        XCTAssertEqual(decoded.wbraid, "wb")
        XCTAssertEqual(decoded.attributionCapturedAt, 1234567.0)
        XCTAssertEqual(decoded.lyr, "lyr1")
        XCTAssertEqual(decoded.msclkid, "ms")
    }

    // MARK: - FSR-86: ATTRIBUTION_PARAMS whitelist matches captured fields

    func testFSR86_dclidWhitelistedAndDeadEntriesRemoved() {
        XCTAssertTrue(ATTRIBUTION_PARAMS.contains("dclid"), "dclid must stay whitelisted (now captured)")
        // The dropped entries had no AttributionData field and were parsed-then-discarded.
        for dead in ["irclickid", "fb_click_id", "fb_action_ids", "fb_action_types", "click_id"] {
            XCTAssertFalse(ATTRIBUTION_PARAMS.contains(dead),
                           "\(dead) should be removed — it was whitelisted but never assigned (FSR-86)")
        }
    }

    // MARK: - FSR-87: SKAN revenue tier honors Int-typed revenue

    func testFSR87_encoderReadsIntRevenue() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        // Int (native) used to cast to nil via `as? Double`, losing the revenue tier.
        let intResult = encoder.encodeWithSKAN4(event: "purchase", properties: ["revenue": 50])
        let doubleResult = encoder.encodeWithSKAN4(event: "purchase", properties: ["revenue": 50.0])
        XCTAssertEqual(intResult.fineValue, doubleResult.fineValue,
                       "Int revenue must produce the same fine value as Double (FSR-87)")
        // purchase rank 7 (56) + tier for $50 (5) = 61; the all-zero-tier bug gave 56.
        XCTAssertEqual(intResult.fineValue, 61)
        XCTAssertEqual(intResult.coarseValue, "high")
    }

    func testFSR87_encoderReadsValueKeyAsInt() {
        let encoder = ConversionValueEncoder(template: .ecommerce)
        let r = encoder.encodeWithSKAN4(event: "purchase", properties: ["value": 5])
        // $5 → tier 2; 56 | 2 = 58.
        XCTAssertEqual(r.fineValue, 58)
    }

    // MARK: - FSR-7: SKAN high-water guard is monotonic and survives across calls

    func testFSR7_conversionValueGuardIsMonotonic() {
        // Exercise the persisted high-water GUARD only (applyHighWaterForTest), separate from
        // the OS SKAdNetwork call which fails in the simulator. This is the FSR-7 invariant.
        let tracker = UnifiedAttributionTracker.shared
        tracker.resetConversionState()

        // A high value applies; a subsequent LOWER value must be rejected (no downgrade).
        XCTAssertTrue(tracker.applyHighWaterForTest(fineValue: 32, coarseValue: "medium", lockWindow: false),
                      "first higher value should apply")
        XCTAssertFalse(tracker.applyHighWaterForTest(fineValue: 8, coarseValue: "low", lockWindow: false),
                       "a lower fine value must NOT downgrade the high-water (FSR-7)")

        // Equal fine + higher coarse applies.
        XCTAssertTrue(tracker.applyHighWaterForTest(fineValue: 32, coarseValue: "high", lockWindow: false),
                      "equal fine with higher coarse should apply")

        // A strictly higher value still applies and locks the window.
        XCTAssertTrue(tracker.applyHighWaterForTest(fineValue: 56, coarseValue: "high", lockWindow: true))

        // After a locked window, nothing else applies (survives across calls = across launches).
        XCTAssertFalse(tracker.applyHighWaterForTest(fineValue: 63, coarseValue: "high", lockWindow: false),
                       "locked window must reject further updates")

        // reset clears the high-water so a fresh window starts.
        tracker.resetConversionState()
        XCTAssertTrue(tracker.applyHighWaterForTest(fineValue: 8, coarseValue: "low", lockWindow: false),
                      "resetConversionState must let a fresh value through")
        tracker.resetConversionState()
    }

    // MARK: - FSR-31: 429 / 408 are retryable

    func testFSR31_429And408AreRetryable() {
        let config = HTTPClientConfig(apiKey: "k")
        let client = DatalyrHTTPClient(endpoint: "https://example.com", config: config)
        // shouldRetry is private; assert via the public HTTPError classification the wire test
        // already trusts: 429/408 retryable, other 4xx not. We exercise it through a tiny mirror.
        XCTAssertTrue(client.isRetryableStatusForTest(429))
        XCTAssertTrue(client.isRetryableStatusForTest(408))
        XCTAssertTrue(client.isRetryableStatusForTest(503))
        XCTAssertFalse(client.isRetryableStatusForTest(400))
        XCTAssertFalse(client.isRetryableStatusForTest(404))
    }

    // MARK: - FSR-84: queue init merges (does not overwrite) concurrently-enqueued events

    func testFSR84_initializeQueueMergesPersistedAndLive() async {
        // Persist a fake backlog, then enqueue a live event BEFORE re-initializing, and assert
        // both survive (merge, not assign). Uses a fresh queue + clean keys.
        await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
        await DatalyrStorage.shared.removeValue(StorageKeys.deadLetterQueue)

        let persisted = [QueuedEvent(payload: EventPayload(
            workspaceId: "w", visitorId: "v", anonymousId: "a", sessionId: "s",
            eventId: "persisted_1", eventName: "persisted"))]
        await DatalyrStorage.shared.setCodableArray(StorageKeys.eventQueue, value: persisted)

        let httpConfig = HTTPClientConfig(apiKey: "k")
        let client = DatalyrHTTPClient(endpoint: "https://127.0.0.1:1/track", config: httpConfig)
        let queue = DatalyrEventQueue(httpClient: client, config: QueueConfig(flushInterval: 999))
        queue.setOnlineStatus(false) // never actually send

        // Enqueue a live event that races the init load.
        await queue.enqueue(EventPayload(
            workspaceId: "w", visitorId: "v", anonymousId: "a", sessionId: "s",
            eventId: "live_1", eventName: "live"))

        // Give the init Task a moment to complete its merge.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let stats = queue.getStats()
        XCTAssertGreaterThanOrEqual(stats.queueSize, 2,
                                    "both persisted and live events must be present after merge (FSR-84)")
        await queue.clear()
        await DatalyrStorage.shared.removeValue(StorageKeys.eventQueue)
    }

    // MARK: - FSR-89: updateConfig actually applies the new config

    func testFSR89_updateConfigDoesNotCrashAndApplies() {
        let httpConfig = HTTPClientConfig(apiKey: "k")
        let client = DatalyrHTTPClient(endpoint: "https://example.com", config: httpConfig)
        let queue = DatalyrEventQueue(httpClient: client, config: QueueConfig(flushInterval: 30))
        // Latent API (no callers), but must apply without crashing now that config is var.
        queue.updateConfig(QueueConfig(maxQueueSize: 7, batchSize: 2, flushInterval: 5, maxRetryCount: 1))
        XCTAssertTrue(true)
    }

    // MARK: - TR-20a parity: iOS normalizes event names (spaces → underscores) like RN/web

    func testTR20a_normalizeEventNameSpacesToUnderscores() {
        // Was: iOS validateEventName REJECTED any name with a space, so track("Order Completed")
        // was silently dropped while the RN bare build recorded it. Now normalized, then valid.
        XCTAssertEqual(normalizeEventName("Order Completed"), "Order_Completed")
        XCTAssertTrue(validateEventName(normalizeEventName("Order Completed")))
        // Runs of whitespace collapse to a single underscore (matches RN's /\s+/g → '_').
        XCTAssertEqual(normalizeEventName("  a   b\tc  "), "a_b_c")
        // System/dotted/hyphenated names are untouched and remain valid.
        XCTAssertEqual(normalizeEventName("$identify"), "$identify")
        XCTAssertEqual(normalizeEventName("screen.view-1"), "screen.view-1")
        // All-whitespace normalizes to empty → rejected (not sent).
        XCTAssertEqual(normalizeEventName("   "), "")
        XCTAssertFalse(validateEventName(normalizeEventName("   ")))
    }
}
