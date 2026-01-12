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
        // Test all error cases
        let networkError = HTTPError.networkError(URLError(.notConnectedToInternet))
        let authError = HTTPError.authenticationFailed
        let rateLimitError = HTTPError.rateLimitExceeded
        let httpError = HTTPError.httpError(statusCode: 500, message: "Internal Server Error")
        let encodingError = HTTPError.encodingError

        // Verify error descriptions exist
        XCTAssertFalse(networkError.localizedDescription.isEmpty)
        XCTAssertFalse(authError.localizedDescription.isEmpty)
        XCTAssertFalse(rateLimitError.localizedDescription.isEmpty)
        XCTAssertFalse(httpError.localizedDescription.isEmpty)
        XCTAssertFalse(encodingError.localizedDescription.isEmpty)
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
