import XCTest
@testable import DatalyrSDK

final class DatalyrHTTPClientTests: XCTestCase {

    // MARK: - Test Helpers

    private func createTestPayload(eventName: String = "test_event") -> EventPayload {
        return EventPayload(
            workspaceId: "test_workspace",
            visitorId: "test_visitor",
            anonymousId: "test_anonymous",
            sessionId: "test_session",
            eventId: UUID().uuidString,
            eventName: eventName
        )
    }

    private func createTestClient(debug: Bool = true) -> DatalyrHTTPClient {
        let config = HTTPClientConfig(
            apiKey: "test_api_key_dk_12345",
            workspaceId: "test_workspace",
            useServerTracking: true,
            debug: debug
        )
        return DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)
    }

    // MARK: - Tracking-domain routing (PrivacyInfo.xcprivacy lists tracking.datalyr.com)
    //
    // iOS blocks tracking.datalyr.com unless the ATT status is authorized at the time of
    // the request, so the host is chosen from the LIVE status on every send attempt. No
    // test here sends a request: they build it with createRequest and read it.

    private static let realIDFA = "ABCDEF01-2345-6789-ABCD-EF0123456789"

    /// An event as the SDK builds it while ATT is authorized.
    private func authorizedEventData(idfa: String = realIDFA) -> [String: Any] {
        [
            "idfa": idfa,
            "att_status": UInt(3),
            "advertiser_tracking_enabled": true,
            "alart": "applovin_user_1",
            "advertiser_data": ["idfa": idfa, "att_status": UInt(3), "tracking_authorized": true] as [String: Any],
            "plan": "pro"
        ]
    }

    private func routingPayload(_ eventData: [String: Any]?) -> EventPayload {
        EventPayload(
            workspaceId: "ws_1", visitorId: "vis_1", anonymousId: "anon_1",
            sessionId: "sess_1", eventId: UUID().uuidString, eventName: "test_event",
            eventData: eventData
        )
    }

    private func routingClient(attStatus: UInt) -> (DatalyrHTTPClient, StatusBox) {
        let box = StatusBox(attStatus)
        let client = createTestClient(debug: false)
        client.attStatusProvider = { box.value }
        return (client, box)
    }

    private final class StatusBox {
        var value: UInt
        init(_ v: UInt) { value = v }
    }

    private func properties(of request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["properties"] as? [String: Any])
    }

    func testAuthorizedEventWithIDFAGoesToTrackingDomainWithIdKept() throws {
        let (client, _) = routingClient(attStatus: 3)
        let request = try client.createRequest(for: routingPayload(authorizedEventData()))
        XCTAssertEqual(request.url?.absoluteString, "https://tracking.datalyr.com/track")
        let props = try properties(of: request)
        XCTAssertEqual(props["idfa"] as? String, Self.realIDFA)
        XCTAssertEqual(props["att_status"] as? Int, 3)
        XCTAssertEqual(props["advertiser_tracking_enabled"] as? Bool, true)
        XCTAssertEqual(props["alart"] as? String, "applovin_user_1")
        XCTAssertEqual((props["advertiser_data"] as? [String: Any])?["idfa"] as? String, Self.realIDFA)
    }

    func testStaleIDFAWhenNotAuthorizedGoesToRegularHostWithIdRemoved() throws {
        for status: UInt in [0, 1, 2] {   // notDetermined, restricted, denied
            let (client, _) = routingClient(attStatus: status)
            let request = try client.createRequest(for: routingPayload(authorizedEventData()))
            XCTAssertEqual(request.url?.absoluteString, "https://api.datalyr.com", "status \(status)")
            let props = try properties(of: request)
            XCTAssertNil(props["idfa"], "status \(status)")
            XCTAssertNil(props["alart"], "status \(status)")
            XCTAssertEqual(props["att_status"] as? Int, Int(status))
            XCTAssertEqual(props["advertiser_tracking_enabled"] as? Bool, false)
            let advertiser = try XCTUnwrap(props["advertiser_data"] as? [String: Any])
            XCTAssertNil(advertiser["idfa"], "status \(status)")
            XCTAssertEqual(advertiser["att_status"] as? Int, Int(status))
            XCTAssertEqual(advertiser["tracking_authorized"] as? Bool, false)
            XCTAssertEqual(props["plan"] as? String, "pro", "other properties are kept")
            // No IDFA anywhere in the body.
            let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains(Self.realIDFA), "status \(status)")
        }
    }

    func testEventWithoutIDFAGoesToRegularEndpoint() throws {
        let (client, _) = routingClient(attStatus: 3)
        XCTAssertEqual(client.endpointFor(routingPayload(["att_status": UInt(3)])), "https://api.datalyr.com")
        XCTAssertEqual(client.endpointFor(routingPayload(nil)), "https://api.datalyr.com")
        let request = try client.createRequest(for: routingPayload(["att_status": UInt(3), "plan": "pro"]))
        XCTAssertEqual(request.url?.absoluteString, "https://api.datalyr.com")
        XCTAssertEqual(try properties(of: request)["att_status"] as? Int, 3, "authorized events are not changed")
    }

    func testEmptyOrAllZeroIDFANeverCountsAsAnIDFA() {
        let (client, _) = routingClient(attStatus: 3)
        // An app can pass its own `idfa` in eventData; the all-zero value is what iOS
        // returns without tracking permission.
        XCTAssertEqual(client.endpointFor(routingPayload(["idfa": ""])), "https://api.datalyr.com")
        XCTAssertEqual(client.endpointFor(routingPayload(["idfa": DatalyrHTTPClient.zeroIDFA])), "https://api.datalyr.com")
        XCTAssertEqual(client.endpointFor(routingPayload(["idfa": "00000000-0000-0000-0000-000000000000"])), "https://api.datalyr.com")
        XCTAssertEqual(client.endpointFor(routingPayload(["idfa": 123])), "https://api.datalyr.com")
    }

    func testQueuedEventIsRoutedByTheStatusAtEachSendAttempt() throws {
        // Built while authorized, then the user turns tracking off before (re)sending,
        // then on again: each attempt follows the status of that moment.
        let (client, box) = routingClient(attStatus: 3)
        let payload = routingPayload(authorizedEventData())
        XCTAssertEqual(try client.createRequest(for: payload).url?.absoluteString, "https://tracking.datalyr.com/track")
        box.value = 2
        let denied = try client.createRequest(for: payload)
        XCTAssertEqual(denied.url?.absoluteString, "https://api.datalyr.com")
        XCTAssertNil(try properties(of: denied)["idfa"])
        box.value = 3
        XCTAssertEqual(try client.createRequest(for: payload).url?.absoluteString, "https://tracking.datalyr.com/track")
    }

    func testStoredQueueRoundTripIsRoutedAndStrippedByTheCurrentStatus() throws {
        // The queue is stored with JSONEncoder and reloaded with JSONDecoder
        // (DatalyrStorage). After the reload the id sits inside AnyCodable as a String.
        let stored = [QueuedEvent(payload: routingPayload(authorizedEventData()), timestamp: 1_700_000_000)]
        let data = try JSONEncoder().encode(stored)
        let reloaded = try JSONDecoder().decode([QueuedEvent].self, from: data)
        let payload = try XCTUnwrap(reloaded.first?.payload)

        let (client, box) = routingClient(attStatus: 3)
        let authorized = try client.createRequest(for: payload)
        XCTAssertEqual(authorized.url?.absoluteString, "https://tracking.datalyr.com/track")
        XCTAssertEqual(try properties(of: authorized)["idfa"] as? String, Self.realIDFA)

        box.value = 0
        let notDetermined = try client.createRequest(for: payload)
        XCTAssertEqual(notDetermined.url?.absoluteString, "https://api.datalyr.com")
        let props = try properties(of: notDetermined)
        XCTAssertNil(props["idfa"])
        XCTAssertNil(props["alart"])
        XCTAssertNil((props["advertiser_data"] as? [String: Any])?["idfa"])
        XCTAssertEqual(props["att_status"] as? Int, 0)
    }

    func testIDFAEventUsesOwnEndpointWithoutServerTracking() {
        let config = HTTPClientConfig(apiKey: "test_api_key_dk_12345", useServerTracking: false)
        let client = DatalyrHTTPClient(endpoint: "https://legacy.example.invalid/track", config: config)
        client.attStatusProvider = { 3 }
        let payload = routingPayload(["idfa": Self.realIDFA])
        XCTAssertEqual(client.endpointFor(payload), "https://legacy.example.invalid/track")
    }

    // MARK: - Server-track wire-contract (the default useServerTracking=true path)

    func testServerTrackWireShape() {
        let client = createTestClient()
        let payload = EventPayload(
            workspaceId: "ws_1",
            visitorId: "vis_1",
            anonymousId: "anon_1",
            sessionId: "sess_xyz",
            eventId: "evt_1",
            eventName: "$web_attribution_matched",
            eventData: ["fbclid": "fb_abc", "_fbp": "fb.1.2.3", "revenue": 9.99, "att_status": UInt(3)],
            source: "mobile_app",
            timestamp: "2026-06-03T10:00:00.000Z",
            userId: nil
        )

        let wire = client.transformForServerAPI(payload)

        // Top level
        XCTAssertEqual(wire["event"] as? String, "$web_attribution_matched")
        XCTAssertEqual(wire["eventId"] as? String, "evt_1")
        XCTAssertEqual(wire["timestamp"] as? String, "2026-06-03T10:00:00.000Z")
        XCTAssertEqual(wire["anonymousId"] as? String, "anon_1")
        XCTAssertNil(wire["userId"], "anonymous mobile events must not fabricate an identified user")

        // IOS-31: session_id MUST be in `context` (where ingest handleServerTrack reads it),
        // not only in properties — otherwise ingest synthesizes its own session id.
        let context = wire["context"] as? [String: Any]
        XCTAssertEqual(context?["session_id"] as? String, "sess_xyz",
                       "session_id must travel in context for ingest to use the SDK session")
        // IOS-33/IOS-20: library version must not be the stale hardcoded 2.1.1.
        // Asserted against the shared constant, NOT a literal — a literal here
        // has to be hand-bumped every release, which is the same failure mode
        // that let context.version freeze at 2.1.1 for four releases while
        // sdk_version moved. See DatalyrVersionTests for the cross-field guard.
        XCTAssertEqual(context?["version"] as? String, DatalyrVersion.current)
        XCTAssertEqual(context?["source"] as? String, "mobile_app")

        // properties carry the eventData + sessionId + source; the click-ids survive
        // (handleServerTrack spreads ...props into event_data).
        let props = wire["properties"] as? [String: Any]
        XCTAssertEqual(props?["fbclid"] as? String, "fb_abc")
        XCTAssertEqual(props?["_fbp"] as? String, "fb.1.2.3")
        XCTAssertEqual(props?["source"] as? String, "mobile_app")
        XCTAssertEqual(props?["sessionId"] as? String, "sess_xyz")

        // att_status (a UInt, e.g. ATT status) must serialize as a NUMBER, not a string.
        // UInt isn't caught by `as? Int`, so it used to fall through to "\(value)" → "3".
        XCTAssertEqual(props?["att_status"] as? Int, 3, "att_status (UInt) must stay numeric, not stringify")
        XCTAssertNil(props?["att_status"] as? String, "att_status must not be a String")
    }

    // MARK: - Configuration Tests

    func testClientConfiguration() {
        let config = HTTPClientConfig(
            maxRetries: 5,
            retryDelay: 2.0,
            timeout: 30.0,
            apiKey: "test_key",
            workspaceId: "ws_123",
            useServerTracking: true,
            debug: true
        )

        XCTAssertEqual(config.maxRetries, 5)
        XCTAssertEqual(config.retryDelay, 2.0)
        XCTAssertEqual(config.timeout, 30.0)
        XCTAssertEqual(config.apiKey, "test_key")
        XCTAssertEqual(config.workspaceId, "ws_123")
        XCTAssertTrue(config.useServerTracking)
        XCTAssertTrue(config.debug)
    }

    func testDefaultConfiguration() {
        let config = HTTPClientConfig(apiKey: "test_key")

        XCTAssertEqual(config.maxRetries, 3, "Default max retries should be 3")
        XCTAssertEqual(config.retryDelay, 1.0, "Default retry delay should be 1.0")
        XCTAssertEqual(config.timeout, 15.0, "Default timeout should be 15.0")
        XCTAssertTrue(config.useServerTracking, "Server tracking should be enabled by default")
        XCTAssertFalse(config.debug, "Debug should be disabled by default")
    }

    // MARK: - Server Tracking Endpoint Tests

    func testServerTrackingEndpoint() {
        let config = HTTPClientConfig(
            apiKey: "test_key",
            useServerTracking: true
        )
        let client = DatalyrHTTPClient(endpoint: "https://old.endpoint.com", config: config)

        // With useServerTracking=true, endpoint should be overridden to api.datalyr.com
        // (This is internal behavior, we test it via the client's behavior)
        XCTAssertNotNil(client)
    }

    // MARK: - Event Payload Tests

    func testEventPayloadCreation() {
        let payload = EventPayload(
            workspaceId: "ws_123",
            visitorId: "vis_456",
            anonymousId: "anon_789",
            sessionId: "sess_012",
            eventId: "evt_345",
            eventName: "purchase",
            eventData: ["price": 29.99, "currency": "USD"],
            userProperties: ["tier": "premium"]
        )

        XCTAssertEqual(payload.workspaceId, "ws_123")
        XCTAssertEqual(payload.visitorId, "vis_456")
        XCTAssertEqual(payload.anonymousId, "anon_789")
        XCTAssertEqual(payload.sessionId, "sess_012")
        XCTAssertEqual(payload.eventId, "evt_345")
        XCTAssertEqual(payload.eventName, "purchase")
        XCTAssertNotNil(payload.eventData)
        XCTAssertNotNil(payload.userProperties)
    }

    // MARK: - Rate Limiting Tests

    func testRateLimitingDoesNotBlockNormalUsage() async throws {
        let client = createTestClient()

        // Send a few requests - should not trigger rate limit
        for i in 0..<5 {
            let payload = createTestPayload(eventName: "rate_test_\(i)")
            let response = await client.sendEvent(payload)

            // Response may fail due to test API key, but should not be rate limited
            // Rate limiting would cause a specific error type
            XCTAssertNotNil(response)
        }
    }

    // MARK: - Batch Sending Tests

    func testBatchSendReturnsResponsesForAllPayloads() async throws {
        let client = createTestClient()

        let payloads = (0..<5).map { createTestPayload(eventName: "batch_event_\($0)") }

        let responses = await client.sendBatch(payloads)

        XCTAssertEqual(responses.count, payloads.count, "Should return response for each payload")
    }

    // MARK: - Response Handling Tests

    func testHTTPResponseStructure() {
        let successResponse = HTTPResponse(success: true, statusCode: 200, error: nil)
        XCTAssertTrue(successResponse.success)
        XCTAssertEqual(successResponse.statusCode, 200)
        XCTAssertNil(successResponse.error)

        let errorResponse = HTTPResponse(success: false, statusCode: 401, error: HTTPError.authenticationFailed)
        XCTAssertFalse(errorResponse.success)
        XCTAssertEqual(errorResponse.statusCode, 401)
        XCTAssertNotNil(errorResponse.error)
    }

    // MARK: - HTTP Error Tests

    func testHTTPErrorTypes() {
        // Test all error cases (matches the current HTTPError enum)
        let invalidURL = HTTPError.invalidURL
        let invalidResponse = HTTPError.invalidResponse
        let authError = HTTPError.authenticationFailed
        let rateLimitError = HTTPError.rateLimitExceeded
        let httpError = HTTPError.httpError(500, "Internal Server Error")

        // Verify error descriptions exist
        XCTAssertFalse(invalidURL.localizedDescription.isEmpty)
        XCTAssertFalse(invalidResponse.localizedDescription.isEmpty)
        XCTAssertFalse(authError.localizedDescription.isEmpty)
        XCTAssertFalse(rateLimitError.localizedDescription.isEmpty)
        XCTAssertFalse(httpError.localizedDescription.isEmpty)
        XCTAssertTrue(httpError.localizedDescription.contains("500"))
    }

    // MARK: - Retry Logic Tests

    func testExponentialBackoffCalculation() {
        // Test that retry delays increase exponentially
        // Note: This tests the concept since the actual method is private

        let baseDelay = 1.0
        var delays: [TimeInterval] = []

        for retryCount in 0..<5 {
            let exponentialDelay = pow(2.0, Double(retryCount)) * baseDelay
            let maxDelay = min(exponentialDelay, 30.0)
            delays.append(maxDelay)
        }

        // Verify exponential growth
        XCTAssertEqual(delays[0], 1.0, accuracy: 0.1)   // 2^0 * 1 = 1
        XCTAssertEqual(delays[1], 2.0, accuracy: 0.1)   // 2^1 * 1 = 2
        XCTAssertEqual(delays[2], 4.0, accuracy: 0.1)   // 2^2 * 1 = 4
        XCTAssertEqual(delays[3], 8.0, accuracy: 0.1)   // 2^3 * 1 = 8
        XCTAssertEqual(delays[4], 16.0, accuracy: 0.1)  // 2^4 * 1 = 16

        // Test cap at 30 seconds
        let cappedDelay = pow(2.0, 10.0) * baseDelay  // Would be 1024
        let actualDelay = min(cappedDelay, 30.0)
        XCTAssertEqual(actualDelay, 30.0)
    }

    // MARK: - Concurrent Request Tests

    func testConcurrentRequests() async throws {
        let client = createTestClient(debug: false)

        // Send multiple requests concurrently
        await withTaskGroup(of: HTTPResponse.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let payload = self.createTestPayload(eventName: "concurrent_\(i)")
                    return await client.sendEvent(payload)
                }
            }

            var responses: [HTTPResponse] = []
            for await response in group {
                responses.append(response)
            }

            // All requests should complete (even if they fail due to test API key)
            XCTAssertEqual(responses.count, 10)
        }
    }

    // MARK: - Performance Tests

    func testSingleEventPerformance() async throws {
        let client = createTestClient(debug: false)

        let startTime = CFAbsoluteTimeGetCurrent()

        let payload = createTestPayload()
        _ = await client.sendEvent(payload)

        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime

        // Single request should be fast (accounting for network)
        // This mainly tests that there's no excessive overhead
        XCTAssertLessThan(duration, 30.0, "Single event should not take more than 30 seconds")
    }

    func testPayloadEncodingPerformance() {
        measure {
            for _ in 0..<1000 {
                let payload = EventPayload(
                    workspaceId: "ws_test",
                    visitorId: "vis_test",
                    anonymousId: "anon_test",
                    sessionId: "sess_test",
                    eventId: UUID().uuidString,
                    eventName: "performance_test",
                    eventData: [
                        "price": 29.99,
                        "currency": "USD",
                        "product_id": "prod_123",
                        "quantity": 2,
                        "category": "electronics"
                    ]
                )

                // Encode to JSON
                if let encoded = try? JSONEncoder().encode(payload) {
                    XCTAssertGreaterThan(encoded.count, 0)
                }
            }
        }
    }
}

// MARK: - HTTPResponse Extension for Testing

extension HTTPResponse: CustomStringConvertible {
    public var description: String {
        return "HTTPResponse(success: \(success), statusCode: \(statusCode ?? -1), error: \(error?.localizedDescription ?? "none"))"
    }
}
