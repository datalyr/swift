import XCTest
@testable import DatalyrSDK

final class DatalyrEventQueueTests: XCTestCase {

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

    // MARK: - Queue Stats Tests

    func testQueueStats_InitialState() async throws {
        // Create a mock HTTP client config
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: true
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: QueueConfig())

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let stats = queue.getStats()

        // Initial state should have empty queue
        XCTAssertEqual(stats.queueSize, 0, "Initial queue should be empty")
        XCTAssertFalse(stats.isProcessing, "Should not be processing initially")
        XCTAssertTrue(stats.isOnline, "Should be online by default")
        XCTAssertNil(stats.oldestEventAge, "No oldest event age when queue is empty")
    }

    func testQueueStats_AfterEnqueue() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: true
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        // Use offline mode to prevent immediate processing
        let queueConfig = QueueConfig(flushInterval: 60.0)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: queueConfig)

        // Set offline to prevent processing
        queue.setOnlineStatus(false)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Enqueue an event
        let payload = createTestPayload()
        await queue.enqueue(payload)

        let stats = queue.getStats()
        XCTAssertEqual(stats.queueSize, 1, "Queue should have 1 event")
    }

    // MARK: - Online/Offline Status Tests

    func testOnlineStatus_Toggle() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: true
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: QueueConfig())

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Initially online
        var stats = queue.getStats()
        XCTAssertTrue(stats.isOnline)

        // Go offline
        queue.setOnlineStatus(false)
        stats = queue.getStats()
        XCTAssertFalse(stats.isOnline)

        // Go online
        queue.setOnlineStatus(true)
        stats = queue.getStats()
        XCTAssertTrue(stats.isOnline)
    }

    // MARK: - Queue Size Limit Tests

    func testQueueSizeLimit() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: true
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        // Create queue with small size limit
        let queueConfig = QueueConfig(maxQueueSize: 5, flushInterval: 60.0)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: queueConfig)

        // Set offline to prevent processing
        queue.setOnlineStatus(false)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Enqueue more events than the limit
        for i in 0..<10 {
            let payload = createTestPayload(eventName: "event_\(i)")
            await queue.enqueue(payload)
        }

        let stats = queue.getStats()

        // Queue should be at max size (oldest events dropped)
        XCTAssertLessThanOrEqual(stats.queueSize, 5, "Queue should respect max size limit")
    }

    // MARK: - Clear Queue Tests

    func testClearQueue() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: true
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        let queueConfig = QueueConfig(flushInterval: 60.0)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: queueConfig)

        // Set offline to prevent processing
        queue.setOnlineStatus(false)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Enqueue events
        for i in 0..<5 {
            let payload = createTestPayload(eventName: "event_\(i)")
            await queue.enqueue(payload)
        }

        var stats = queue.getStats()
        XCTAssertGreaterThan(stats.queueSize, 0, "Queue should have events")

        // Clear the queue
        await queue.clear()

        stats = queue.getStats()
        XCTAssertEqual(stats.queueSize, 0, "Queue should be empty after clear")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentEnqueue() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: true
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        let queueConfig = QueueConfig(maxQueueSize: 100, flushInterval: 60.0)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: queueConfig)

        // Set offline to prevent processing
        queue.setOnlineStatus(false)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Enqueue events concurrently from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let payload = self.createTestPayload(eventName: "concurrent_event_\(i)")
                    await queue.enqueue(payload)
                }
            }
        }

        let stats = queue.getStats()

        // All events should be queued (up to max size)
        XCTAssertGreaterThan(stats.queueSize, 0, "Should have queued events")
        XCTAssertLessThanOrEqual(stats.queueSize, 100, "Should respect max queue size")
    }

    func testConcurrentOnlineStatusToggle() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: true
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: QueueConfig())

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        // Toggle online status concurrently (should not crash)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    queue.setOnlineStatus(i % 2 == 0)
                }
            }
        }

        // Should complete without crash - getting stats should work
        let stats = queue.getStats()
        XCTAssertNotNil(stats)
    }

    // MARK: - Performance Tests

    func testEnqueuePerformance() async throws {
        let config = HTTPClientConfig(
            apiKey: "test_api_key",
            debug: false
        )
        let httpClient = DatalyrHTTPClient(endpoint: "https://api.datalyr.com", config: config)

        let queueConfig = QueueConfig(maxQueueSize: 1000, flushInterval: 60.0)
        let queue = DatalyrEventQueue(httpClient: httpClient, config: queueConfig)

        // Set offline to prevent processing
        queue.setOnlineStatus(false)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)

        let startTime = CFAbsoluteTimeGetCurrent()

        // Enqueue many events
        for i in 0..<100 {
            let payload = createTestPayload(eventName: "perf_event_\(i)")
            await queue.enqueue(payload)
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime

        // Should complete in reasonable time (< 1 second for 100 events)
        XCTAssertLessThan(duration, 1.0, "Enqueuing 100 events should take less than 1 second")
    }
}

// MARK: - QueueStats Extension for Testing

extension QueueStats: CustomStringConvertible {
    public var description: String {
        return "QueueStats(size: \(queueSize), processing: \(isProcessing), online: \(isOnline))"
    }
}
