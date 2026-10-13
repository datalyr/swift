import XCTest
@testable import DatalyrSDK

/// 2.1.18: the deferred web→app lookup carries the live ATT status, treats
/// `att_not_authorized` as "no answer yet", re-runs once tracking is allowed, and device
/// context travels as `device_context`.
final class ATTDeferredLookupTests: XCTestCase {

    // MARK: - att_status in the request body

    func testRequestBodyCarriesATTStatusAsNumber() throws {
        for status: UInt in 0...3 {
            let body = DeferredLookup.requestBody(
                osVersion: "18.1", deviceModel: "iPhone16,1", timezone: "Europe/London",
                language: "en-GB", attStatus: status
            )
            XCTAssertEqual(body["att_status"] as? Int, Int(status))
            XCTAssertEqual(body["platform"] as? String, "ios")
            XCTAssertEqual(body["language"] as? String, "en-GB")

            // On the wire it must be a JSON number, not a string.
            let data = try JSONSerialization.data(withJSONObject: body)
            let json = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(json.contains("\"att_status\":\(status)"), json)
        }
    }

    func testRequestBodyOmitsEmptyLanguage() {
        let body = DeferredLookup.requestBody(
            osVersion: "18.1", deviceModel: "iPhone16,1", timezone: "UTC", language: "", attStatus: 3
        )
        XCTAssertNil(body["language"])
    }

    // MARK: - Answer handling

    func testATTNotAuthorizedIsNotFinal() {
        let json: [String: Any] = ["found": false, "reason": "att_not_authorized"]
        XCTAssertEqual(DeferredLookup.disposition(forBody: json, installAgeMinutes: 5), .awaitingATT)
        XCTAssertEqual(DeferredLookup.disposition(forBody: json, installAgeMinutes: 6000), .awaitingATT)
        XCTAssertEqual(DeferredLookup.disposition(forBody: json, installAgeMinutes: nil), .awaitingATT)
    }

    func testOtherAnswersKeepTheirDisposition() {
        XCTAssertEqual(DeferredLookup.disposition(forBody: ["found": true], installAgeMinutes: 1), .resolve)
        XCTAssertEqual(DeferredLookup.disposition(
            forBody: ["found": false, "reason": "no_candidates"], installAgeMinutes: 10), .retryLater)
        XCTAssertEqual(DeferredLookup.disposition(
            forBody: ["found": false, "reason": "no_candidates"], installAgeMinutes: 120), .resolve)
        XCTAssertEqual(DeferredLookup.disposition(
            forBody: ["found": false], installAgeMinutes: 10), .retryLater, "missing reason = no_candidates")
        XCTAssertEqual(DeferredLookup.disposition(
            forBody: ["found": false, "reason": "not_enabled"], installAgeMinutes: 10), .resolve)

        XCTAssertEqual(DeferredLookup.disposition(forHTTPStatus: 503), .retryLater,
                       "an unreadable server decision (503) is retried")
        XCTAssertEqual(DeferredLookup.disposition(forHTTPStatus: 429), .retryLater)
        XCTAssertEqual(DeferredLookup.disposition(forHTTPStatus: 408), .retryLater)
        XCTAssertEqual(DeferredLookup.disposition(forHTTPStatus: 401), .resolve)
        XCTAssertEqual(DeferredLookup.disposition(forHTTPStatus: 410), .resolve)
    }

    /// The SDK spends an attempt before each request and refunds it on att_not_authorized,
    /// so any number of declined lookups leaves the install eligible with its full budget.
    func testATTNotAuthorizedDoesNotConsumeAttemptsOrResolve() async {
        await DatalyrStorage.shared.removeValue(StorageKeys.firstLaunchTime)
        await DatalyrStorage.shared.removeValue(StorageKeys.deferredLookupResolved)
        await DatalyrStorage.shared.removeValue(StorageKeys.deferredLookupAttempts)

        let manager = AttributionManager()
        await manager.initialize()

        for _ in 0..<10 {
            let eligible = await manager.shouldAttemptDeferredLookup()
            XCTAssertTrue(eligible)
            await manager.recordDeferredLookupAttempt()
            await manager.refundDeferredLookupAttempt()
        }
        let attempts = await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupAttempts) ?? 0
        XCTAssertEqual(attempts, 0)
        let resolved = await DatalyrStorage.shared.getBool(StorageKeys.deferredLookupResolved) ?? false
        XCTAssertFalse(resolved)

        // A real failure still counts.
        await manager.recordDeferredLookupAttempt()
        let afterFailure = await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupAttempts) ?? 0
        XCTAssertEqual(afterFailure, 1)

        // Refund never goes below zero.
        await DatalyrStorage.shared.removeValue(StorageKeys.deferredLookupAttempts)
        await manager.refundDeferredLookupAttempt()
        let floor = await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupAttempts) ?? 0
        XCTAssertEqual(floor, 0)

        await manager.markDeferredLookupResolved()
    }

    func testATTMissReportedOncePerLaunch() {
        let coordinator = DeferredLookupCoordinator()
        XCTAssertTrue(coordinator.shouldReportATTMiss())
        XCTAssertFalse(coordinator.shouldReportATTMiss())
        XCTAssertFalse(coordinator.shouldReportATTMiss())
    }

    // MARK: - Re-run on grant

    func testATTTransitionDetection() {
        let c = DeferredLookupCoordinator()
        XCTAssertFalse(c.observeATTStatus(0), "first read is the baseline")
        XCTAssertFalse(c.observeATTStatus(0))
        XCTAssertTrue(c.observeATTStatus(3), "notDetermined → authorized")
        XCTAssertFalse(c.observeATTStatus(3), "no second trigger for the same grant")
        XCTAssertFalse(c.observeATTStatus(2))
        XCTAssertTrue(c.observeATTStatus(3), "denied → authorized (changed in Settings)")

        let alreadyAuthorized = DeferredLookupCoordinator()
        XCTAssertFalse(alreadyAuthorized.observeATTStatus(3),
                       "authorized at launch: the init lookup already carries 3")
    }

    /// End to end over the real pieces: lookup at launch with ATT undetermined is declined,
    /// the user allows tracking, and the re-run goes out with att_status 3 — within the
    /// original attempt budget.
    func testLookupRerunsAfterGrantWithStatus3() async {
        await DatalyrStorage.shared.removeValue(StorageKeys.firstLaunchTime)
        await DatalyrStorage.shared.removeValue(StorageKeys.deferredLookupResolved)
        await DatalyrStorage.shared.removeValue(StorageKeys.deferredLookupAttempts)

        let manager = AttributionManager()
        await manager.initialize()
        let coordinator = DeferredLookupCoordinator()
        var liveATT: UInt = 0
        var sentStatuses: [Int] = []

        // Mirrors DatalyrSDK.fetchDeferredWebAttribution's bookkeeping.
        let lookup: () async -> Void = {
            let body = DeferredLookup.requestBody(
                osVersion: "18", deviceModel: "iPhone", timezone: "UTC", language: nil, attStatus: liveATT
            )
            sentStatuses.append(body["att_status"] as? Int ?? -1)
            await manager.recordDeferredLookupAttempt()
            let answer: [String: Any] = liveATT == 3
                ? ["found": false, "reason": "no_candidates"]
                : ["found": false, "reason": "att_not_authorized"]
            switch DeferredLookup.disposition(forBody: answer, installAgeMinutes: 600) {
            case .resolve: await manager.markDeferredLookupResolved()
            case .retryLater: break
            case .awaitingATT: await manager.refundDeferredLookupAttempt()
            }
        }
        let eligible: () async -> Bool = { await manager.shouldAttemptDeferredLookup() }

        _ = coordinator.observeATTStatus(liveATT)
        await coordinator.run(isEligible: eligible, lookup: lookup)   // launch
        XCTAssertEqual(sentStatuses, [0])
        var stillEligible = await manager.shouldAttemptDeferredLookup()
        XCTAssertTrue(stillEligible, "att_not_authorized leaves the lookup open")

        // Foreground without a change: nothing runs.
        if coordinator.observeATTStatus(liveATT) {
            await coordinator.run(isEligible: eligible, lookup: lookup)
        }
        XCTAssertEqual(sentStatuses, [0])

        // User allows tracking.
        liveATT = 3
        if coordinator.observeATTStatus(liveATT) {
            await coordinator.run(isEligible: eligible, lookup: lookup)
        }
        XCTAssertEqual(sentStatuses, [0, 3])
        let attempts = await DatalyrStorage.shared.getDouble(StorageKeys.deferredLookupAttempts) ?? 0
        XCTAssertEqual(attempts, 1, "only the answered lookup used an attempt")
        stillEligible = await manager.shouldAttemptDeferredLookup()
        XCTAssertFalse(stillEligible, "the post-grant answer is definitive")
    }

    /// No double in-flight lookups: a grant arriving mid-request queues exactly one re-run.
    func testRunIsSingleFlightAndQueuesOneRerun() async {
        let coordinator = DeferredLookupCoordinator()
        let started = expectation(description: "first lookup started")
        var gate: CheckedContinuation<Void, Never>?
        var runs = 0
        var maxConcurrent = 0
        var concurrent = 0

        let first = Task {
            await coordinator.run(isEligible: { true }, lookup: {
                runs += 1
                concurrent += 1
                maxConcurrent = max(maxConcurrent, concurrent)
                if runs == 1 {
                    await withCheckedContinuation { c in
                        gate = c
                        started.fulfill()
                    }
                }
                concurrent -= 1
            })
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(coordinator.isInFlight)

        // Two more triggers while in flight (e.g. updateTrackingAuthorization + didBecomeActive).
        await coordinator.run(isEligible: { true }, lookup: { XCTFail("must not start a second lookup") })
        await coordinator.run(isEligible: { true }, lookup: { XCTFail("must not start a second lookup") })

        gate?.resume()
        await first.value

        XCTAssertEqual(runs, 2, "the in-flight lookup plus exactly one queued re-run")
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertFalse(coordinator.isInFlight)

        // Slot is free again afterwards.
        var later = 0
        await coordinator.run(isEligible: { true }, lookup: { later += 1 })
        XCTAssertEqual(later, 1)
        await coordinator.run(isEligible: { false }, lookup: { XCTFail("ineligible") })
    }

    // MARK: - device_context wire key

    private func payloadWithContext() -> EventPayload {
        EventPayload(
            workspaceId: "ws", visitorId: "vis", anonymousId: "anon", sessionId: "sess",
            eventId: "evt", eventName: "purchase",
            deviceContext: DeviceContext(
                deviceId: "dev-123",
                deviceInfo: DeviceInfo(model: "iPhone", manufacturer: "Apple", osVersion: "18.1",
                                       screenSize: "1179x2556", timezone: "UTC")
            ),
            timestamp: "2026-10-13T00:00:00.000Z"
        )
    }

    func testServerTrackSendsDeviceContextKey() {
        let client = DatalyrHTTPClient(
            endpoint: "", config: HTTPClientConfig(apiKey: "k", workspaceId: "ws", useServerTracking: true)
        )
        let props = client.transformForServerAPI(payloadWithContext())["properties"] as? [String: Any]
        let ctx = props?["device_context"] as? [String: Any]
        XCTAssertEqual(ctx?["deviceId"] as? String, "dev-123")
        XCTAssertNil(props?["fingerprint"], "the old key is no longer sent")
    }

    func testLegacyWireUsesDeviceContextAndDiskKeepsOldKey() throws {
        let payload = payloadWithContext()

        let wire = try JSONSerialization.jsonObject(
            with: EventPayload.wireEncoder().encode(payload)) as? [String: Any]
        XCTAssertNotNil(wire?["device_context"])
        XCTAssertNil(wire?["fingerprintData"])

        let disk = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)) as? [String: Any]
        XCTAssertNotNil(disk?["fingerprintData"], "on-disk key unchanged so a downgrade can still read the queue")
        XCTAssertNil(disk?["device_context"])

        // Both shapes decode.
        let fromWire = try JSONDecoder().decode(EventPayload.self, from: EventPayload.wireEncoder().encode(payload))
        XCTAssertEqual(fromWire.deviceContext?.deviceId, "dev-123")
        let fromDisk = try JSONDecoder().decode(EventPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(fromDisk.deviceContext?.deviceId, "dev-123")
    }

    /// A queue persisted by 2.1.17 (synthesized Codable, `fingerprintData` key) still decodes.
    func testOldDiskQueueDecodes() throws {
        let legacy = """
        [{"payload":{"workspaceId":"ws","visitorId":"vis","anonymousId":"anon","sessionId":"sess",
          "eventId":"evt","eventName":"purchase","eventData":{"value":9.99,"currency":"USD"},
          "fingerprintData":{"deviceId":"dev-old","deviceInfo":{"model":"iPhone","manufacturer":"Apple",
          "osVersion":"17.0","screenSize":"1x1","timezone":"UTC","isEmulator":false}},
          "source":"mobile_app","timestamp":"2026-10-01T00:00:00.000Z","userId":"u1"},
          "timestamp":1759276800,"retryCount":2}]
        """
        let queue = try JSONDecoder().decode([QueuedEvent].self, from: Data(legacy.utf8))
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue[0].payload.deviceContext?.deviceId, "dev-old")
        XCTAssertEqual(queue[0].payload.deviceContext?.deviceInfo?.osVersion, "17.0")
        XCTAssertEqual(queue[0].payload.userId, "u1")
        XCTAssertEqual(queue[0].retryCount, 2)
        XCTAssertEqual(queue[0].payload.eventData?["currency"]?.value as? String, "USD")

        // And an event without device context.
        let bare = """
        {"workspaceId":"ws","visitorId":"v","anonymousId":"a","sessionId":"s","eventId":"e",
         "eventName":"x","source":"mobile_app","timestamp":"t"}
        """
        let p = try JSONDecoder().decode(EventPayload.self, from: Data(bare.utf8))
        XCTAssertNil(p.deviceContext)
        XCTAssertNil(p.eventData)
    }
}
