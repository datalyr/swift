import XCTest
@testable import DatalyrSDK

/// Tests for thread safety of SDK components
final class ThreadSafetyTests: XCTestCase {

    // MARK: - HTTP Client Rate Limiter Tests

    func testRateLimiterConcurrentAccess() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: false
        )
        let client = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        // Hammer the rate limiter from multiple concurrent tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let payload = EventPayload(
                        workspaceId: "test",
                        visitorId: "test",
                        anonymousId: "test",
                        sessionId: "test",
                        eventId: UUID().uuidString,
                        eventName: "concurrent_test_\(i)"
                    )
                    // This should not crash due to race conditions
                    _ = await client.sendEvent(payload)
                }
            }
        }

        // If we get here without a crash, the test passes
        XCTAssertTrue(true, "Concurrent rate limiter access did not crash")
    }

    // MARK: - Event Queue Thread Safety Tests

    func testEventQueueConcurrentEnqueueAndStatusChange() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: false
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        let queueConfig = QueueConfig(maxQueueSize: 100, flushInterval: 60.0)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: queueConfig)

        // Set offline initially
        queue.setOnlineStatus(false)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Run concurrent operations
        await withTaskGroup(of: Void.self) { group in
            // Enqueue events
            for i in 0..<50 {
                group.addTask {
                    let payload = EventPayload(
                        workspaceId: "test",
                        visitorId: "test",
                        anonymousId: "test",
                        sessionId: "test",
                        eventId: UUID().uuidString,
                        eventName: "thread_test_\(i)"
                    )
                    await queue.enqueue(payload)
                }
            }

            // Toggle online status
            for i in 0..<50 {
                group.addTask {
                    queue.setOnlineStatus(i % 2 == 0)
                }
            }

            // Get stats
            for _ in 0..<50 {
                group.addTask {
                    _ = queue.getStats()
                }
            }
        }

        // Should complete without crash
        let stats = queue.getStats()
        XCTAssertGreaterThanOrEqual(stats.queueSize, 0)
    }

    func testEventQueueConcurrentFlush() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: false
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        let queueConfig = QueueConfig(flushInterval: 60.0)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: queueConfig)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Add some events
        for i in 0..<10 {
            let payload = EventPayload(
                workspaceId: "test",
                visitorId: "test",
                anonymousId: "test",
                sessionId: "test",
                eventId: UUID().uuidString,
                eventName: "flush_test_\(i)"
            )
            await queue.enqueue(payload)
        }

        // Trigger multiple concurrent flushes
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await queue.flush()
                }
            }
        }

        // Should complete without crash or deadlock
        XCTAssertTrue(true, "Concurrent flush did not cause issues")
    }

    // MARK: - Storage Thread Safety Tests

    func testStorageConcurrentAccess() async throws {
        let storage = DatalyrStorage.shared

        // Concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<50 {
                group.addTask {
                    await storage.setString("test_key_\(i % 10)", value: "value_\(i)")
                }
            }

            // Readers
            for i in 0..<50 {
                group.addTask {
                    _ = await storage.getString("test_key_\(i % 10)")
                }
            }

            // Delete operations
            for i in 0..<20 {
                group.addTask {
                    await storage.removeValue("test_key_\(i % 10)")
                }
            }
        }

        // Should complete without crash
        XCTAssertTrue(true, "Concurrent storage access did not crash")

        // Cleanup
        for i in 0..<10 {
            await storage.removeValue("test_key_\(i)")
        }
    }

    // MARK: - Conversion Value Encoder Thread Safety Tests

    func testConversionEncoderConcurrentAccess() async throws {
        let encoder = ConversionValueEncoder(template: .ecommerce)

        // Concurrent encoding from multiple tasks
        await withTaskGroup(of: Int.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let revenue = Double(i % 10) * 10.0
                    return encoder.encode(event: "purchase", properties: ["revenue": revenue])
                }
            }

            var results: [Int] = []
            for await result in group {
                results.append(result)
            }

            XCTAssertEqual(results.count, 100, "All encoding operations should complete")

            // Verify all results are valid conversion values
            for result in results {
                XCTAssertGreaterThanOrEqual(result, 0)
                XCTAssertLessThanOrEqual(result, 63)
            }
        }
    }

    // MARK: - SDK Singleton Thread Safety Tests

    func testSDKSingletonConcurrentAccess() async throws {
        // Access singleton from multiple concurrent tasks
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let sdk = DatalyrSDK.shared
                    return sdk.getStatus().initialized
                }
            }

            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }

            // All accesses should return the same result
            let firstResult = results.first ?? false
            for result in results {
                XCTAssertEqual(result, firstResult, "All concurrent accesses should return same initialization state")
            }
        }
    }

    // MARK: - Stress Tests

    func testHighConcurrencyStress() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: false
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        let queueConfig = QueueConfig(maxQueueSize: 500, flushInterval: 60.0)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: queueConfig)

        // Set offline to prevent network calls
        queue.setOnlineStatus(false)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        let startTime = CFAbsoluteTimeGetCurrent()

        // High concurrency stress test
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<500 {
                group.addTask {
                    let payload = EventPayload(
                        workspaceId: "stress_test",
                        visitorId: "visitor_\(i % 10)",
                        anonymousId: "anon_\(i % 10)",
                        sessionId: "session_\(i % 5)",
                        eventId: UUID().uuidString,
                        eventName: "stress_event_\(i)"
                    )
                    await queue.enqueue(payload)
                }
            }
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime

        // Should complete in reasonable time
        XCTAssertLessThan(duration, 10.0, "500 concurrent enqueues should complete within 10 seconds")

        let stats = queue.getStats()
        XCTAssertGreaterThan(stats.queueSize, 0, "Queue should have events")
    }

    // MARK: - Deadlock Prevention Tests

    func testNoDeadlockOnRapidStatusChanges() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: false
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        let queue = DatalyrEventQueue(httpClient: httpClient, config: QueueConfig())

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Rapid status changes should not cause deadlock
        let expectation = XCTestExpectation(description: "No deadlock")

        Task {
            for _ in 0..<1000 {
                queue.setOnlineStatus(true)
                queue.setOnlineStatus(false)
            }
            expectation.fulfill()
        }

        // Wait with timeout - if we hit timeout, there's likely a deadlock
        await fulfillment(of: [expectation], timeout: 5.0)
    }

    // MARK: - Memory Consistency Tests

    func testQueueStateMemoryconsistency() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: false
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        let queue = DatalyrEventQueue(httpClient: httpClient, config: QueueConfig())

        // Set to known state
        queue.setOnlineStatus(true)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Read state from multiple threads and verify consistency
        var onlineStates: [Bool] = []

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    return queue.getStats().isOnline
                }
            }

            for await state in group {
                onlineStates.append(state)
            }
        }

        // All reads should see the same state
        let allSame = onlineStates.allSatisfy { $0 == onlineStates.first }
        XCTAssertTrue(allSame, "All concurrent reads should see consistent state")
    }
}
