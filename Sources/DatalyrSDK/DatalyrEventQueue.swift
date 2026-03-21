import Foundation

// MARK: - Queue Configuration

/// Configuration for event queue
internal struct QueueConfig {
    let maxQueueSize: Int
    let batchSize: Int
    let flushInterval: TimeInterval
    let maxRetryCount: Int
    
    init(
        maxQueueSize: Int = 100,
        batchSize: Int = 10,
        flushInterval: TimeInterval = 30.0,
        maxRetryCount: Int = 3
    ) {
        self.maxQueueSize = maxQueueSize
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.maxRetryCount = maxRetryCount
    }
}

// MARK: - Event Queue

/// Event queue for offline storage and batching
internal class DatalyrEventQueue {
    private let httpClient: DatalyrHTTPClient
    private let config: QueueConfig
    private let storage = DatalyrStorage.shared
    private var queue: [QueuedEvent] = []
    private var flushTimer: Timer?
    private var _isProcessing = false
    private var _isOnline = true

    // Thread-safe queue management - all mutable state protected by queueLock
    private let queueLock = NSLock()
    private let processingQueue = DispatchQueue(label: "com.datalyr.eventqueue", qos: .utility)

    // Thread-safe accessors for state flags
    private var isProcessing: Bool {
        get { queueLock.withLock { _isProcessing } }
        set { queueLock.withLock { _isProcessing = newValue } }
    }

    private var isOnline: Bool {
        get { queueLock.withLock { _isOnline } }
        set { queueLock.withLock { _isOnline = newValue } }
    }
    
    init(httpClient: DatalyrHTTPClient, config: QueueConfig = QueueConfig()) {
        self.httpClient = httpClient
        self.config = config
        
        Task {
            await initializeQueue()
        }
    }
    
    // MARK: - Public Methods
    
    /// Add an event to the queue
    func enqueue(_ payload: EventPayload) async {
        let queuedEvent = QueuedEvent(payload: payload)

        // Add to queue under lock
        let shouldFlush: Bool = queueLock.withLock {
            // Check queue size limit
            if queue.count >= config.maxQueueSize {
                debugLog("Queue is full, removing oldest event")
                queue.removeFirst()
            }

            queue.append(queuedEvent)
            debugLog("Event queued: \(payload.eventName) (queue size: \(queue.count))")

            // Check if we should flush (while still holding lock)
            return _isOnline && !_isProcessing
        }

        // Persist to storage (outside lock)
        await persistQueue()

        // Try to flush immediately if online
        if shouldFlush {
            await processQueue()
        }
    }
    
    /// Manually flush the queue
    func flush() async {
        debugLog("Manual flush requested")
        await processQueue()
    }
    
    /// Set online/offline status
    func setOnlineStatus(_ online: Bool) {
        let shouldProcess: Bool = queueLock.withLock {
            let wasOnline = _isOnline
            _isOnline = online
            // Return true if we just came online and aren't already processing
            return !wasOnline && online && !_isProcessing
        }

        debugLog("Network status changed: \(online ? "online" : "offline")")

        // If we just came online, try to process the queue
        if shouldProcess {
            Task {
                await processQueue()
            }
        }
    }
    
    /// Get queue statistics
    func getStats() -> QueueStats {
        return queueLock.withLock {
            let oldestEventAge: TimeInterval? = queue.first.map { queuedEvent in
                Date().timeIntervalSince1970 - queuedEvent.timestamp
            }
            return QueueStats(
                queueSize: queue.count,
                isProcessing: _isProcessing,
                isOnline: _isOnline,
                oldestEventAge: oldestEventAge
            )
        }
    }

    /// Clear the queue
    func clear() async {
        queueLock.withLock { queue.removeAll() }
        await storage.removeValue(StorageKeys.eventQueue)
        debugLog("Event queue cleared")
    }
    
    /// Update queue configuration
    func updateConfig(_ newConfig: QueueConfig) {
        // Stop current timer
        stopFlushTimer()
        
        // Start new timer with updated interval
        startFlushTimer()
        
        debugLog("Queue configuration updated")
    }
    
    /// Destroy the queue (cleanup)
    func destroy() {
        stopFlushTimer()
        
        // Save current queue state
        Task {
            await persistQueue()
        }
        
        debugLog("Event queue destroyed")
    }
    
    // MARK: - Private Methods
    
    /// Initialize the queue by loading persisted events
    private func initializeQueue() async {
        if let persistedQueue = await storage.getCodableArray(StorageKeys.eventQueue, type: QueuedEvent.self) {
            let count = queueLock.withLock {
                queue = persistedQueue
                return queue.count
            }
            debugLog("Loaded \(count) events from storage")
        }

        startFlushTimer()
    }
    
    /// Process the queue and send events
    private func processQueue() async {
        // Atomic check-and-set to prevent concurrent processing
        let canProcess: Bool = queueLock.withLock {
            guard !_isProcessing && !queue.isEmpty else { return false }
            _isProcessing = true
            return true
        }

        guard canProcess else { return }

        debugLog("Processing queue with \(queueLock.withLock { queue.count }) events")

        await processQueueInternal()

        queueLock.withLock { _isProcessing = false }
    }
    
    /// Internal queue processing logic
    private func processQueueInternal() async {
        // Get events to process (up to batch size)
        let eventsToProcess: [QueuedEvent] = queueLock.withLock {
            let batchSize = min(config.batchSize, queue.count)
            return Array(queue.prefix(batchSize))
        }

        var processedEvents: [QueuedEvent] = []

        // Process events
        for queuedEvent in eventsToProcess {
            let response = await httpClient.sendEvent(queuedEvent.payload)

            if response.success {
                debugLog("Event sent successfully: \(queuedEvent.payload.eventName)")
                processedEvents.append(queuedEvent)
            } else {
                var updatedEvent = queuedEvent
                updatedEvent.retryCount += 1

                if updatedEvent.retryCount >= config.maxRetryCount {
                    debugLog("Event exceeded max retries, dropping: \(queuedEvent.payload.eventName)")
                    processedEvents.append(queuedEvent)
                } else {
                    debugLog("Event failed, will retry: \(queuedEvent.payload.eventName) (attempt \(updatedEvent.retryCount))")
                    queueLock.withLock {
                        if let index = queue.firstIndex(where: { $0.payload.eventId == queuedEvent.payload.eventId }) {
                            queue[index] = updatedEvent
                        }
                    }
                }
            }
        }

        // Remove successfully processed events from queue
        if !processedEvents.isEmpty {
            queueLock.withLock {
                queue.removeAll { processedEvent in
                    processedEvents.contains { $0.payload.eventId == processedEvent.payload.eventId }
                }
            }
            await persistQueue()
        }
    }

    /// Persist queue to storage
    private func persistQueue() async {
        let currentQueue = queueLock.withLock { queue }
        await storage.setCodableArray(StorageKeys.eventQueue, value: currentQueue)
    }
    
    /// Start the periodic flush timer
    private func startFlushTimer() {
        stopFlushTimer() // Stop any existing timer

        flushTimer = Timer.scheduledTimer(withTimeInterval: config.flushInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Thread-safe check of state
            let shouldFlush = self.queueLock.withLock {
                self._isOnline && !self.queue.isEmpty
            }

            if shouldFlush {
                Task {
                    await self.processQueue()
                }
            }
        }

        debugLog("Flush timer started with interval: \(config.flushInterval)s")
    }
    
    /// Stop the flush timer
    private func stopFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
        debugLog("Flush timer stopped")
    }
}

// MARK: - DispatchQueue Extension

extension DispatchQueue {
    func asyncTask(_ task: @escaping () async -> Void) {
        self.async {
            Task {
                await task()
            }
        }
    }
} 