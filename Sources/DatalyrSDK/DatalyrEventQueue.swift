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
    private var isProcessing = false
    private var isOnline = true
    
    // Queue management
    private let queueLock = NSLock()
    private let processingQueue = DispatchQueue(label: "com.datalyr.eventqueue", qos: .utility)
    
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
        
        queueLock.lock()
        defer { queueLock.unlock() }
        
        // Check queue size limit
        if queue.count >= config.maxQueueSize {
            debugLog("Queue is full, removing oldest event")
            queue.removeFirst()
        }
        
        queue.append(queuedEvent)
        debugLog("Event queued: \(payload.eventName) (queue size: \(queue.count))")
        
        // Persist to storage
        await persistQueue()
        
        // Try to flush immediately if online
        if isOnline && !isProcessing {
            Task {
                await processQueue()
            }
        }
    }
    
    /// Manually flush the queue
    func flush() async {
        debugLog("Manual flush requested")
        await processQueue()
    }
    
    /// Set online/offline status
    func setOnlineStatus(_ online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        
        debugLog("Network status changed: \(online ? "online" : "offline")")
        
        // If we just came online, try to process the queue
        if !wasOnline && online && !isProcessing {
            Task {
                await processQueue()
            }
        }
    }
    
    /// Get queue statistics
    func getStats() -> QueueStats {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let oldestEventAge: TimeInterval? = queue.first?.timestamp.timeIntervalSince1970
            .map { Date().timeIntervalSince1970 - $0 }
        
        return QueueStats(
            queueSize: queue.count,
            isProcessing: isProcessing,
            isOnline: isOnline,
            oldestEventAge: oldestEventAge
        )
    }
    
    /// Clear the queue
    func clear() async {
        queueLock.lock()
        queue.removeAll()
        queueLock.unlock()
        
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
        do {
            if let persistedQueue = await storage.getCodableArray(StorageKeys.eventQueue, type: QueuedEvent.self) {
                queueLock.lock()
                queue = persistedQueue
                queueLock.unlock()
                
                debugLog("Loaded \(queue.count) events from storage")
            }
            
            // Start the flush timer
            startFlushTimer()
        } catch {
            errorLog("Failed to initialize event queue", error: error)
        }
    }
    
    /// Process the queue and send events
    private func processQueue() async {
        guard !isProcessing && !queue.isEmpty else { return }
        
        isProcessing = true
        debugLog("Processing queue with \(queue.count) events")
        
        await processingQueue.asyncTask {
            await self.processQueueInternal()
        }
        
        isProcessing = false
    }
    
    /// Internal queue processing logic
    private func processQueueInternal() async {
        var eventsToProcess: [QueuedEvent] = []
        
        // Get events to process (up to batch size)
        queueLock.lock()
        let batchSize = min(config.batchSize, queue.count)
        eventsToProcess = Array(queue.prefix(batchSize))
        queueLock.unlock()
        
        var processedEvents: [QueuedEvent] = []
        
        // Process events
        for queuedEvent in eventsToProcess {
            let response = await httpClient.sendEvent(queuedEvent.payload)
            
            if response.success {
                debugLog("Event sent successfully: \(queuedEvent.payload.eventName)")
                processedEvents.append(queuedEvent)
            } else {
                // Increment retry count
                var updatedEvent = queuedEvent
                updatedEvent.retryCount += 1
                
                if updatedEvent.retryCount >= config.maxRetryCount {
                    debugLog("Event exceeded max retries, dropping: \(queuedEvent.payload.eventName)")
                    processedEvents.append(queuedEvent) // Remove from queue
                } else {
                    debugLog("Event failed, will retry: \(queuedEvent.payload.eventName) (attempt \(updatedEvent.retryCount))")
                    // Update the event in the queue
                    queueLock.lock()
                    if let index = queue.firstIndex(where: { $0.payload.eventId == queuedEvent.payload.eventId }) {
                        queue[index] = updatedEvent
                    }
                    queueLock.unlock()
                }
            }
        }
        
        // Remove successfully processed events from queue
        if !processedEvents.isEmpty {
            queueLock.lock()
            queue.removeAll { processedEvent in
                processedEvents.contains { $0.payload.eventId == processedEvent.payload.eventId }
            }
            queueLock.unlock()
            
            // Persist updated queue
            await persistQueue()
        }
    }
    
    /// Persist queue to storage
    private func persistQueue() async {
        queueLock.lock()
        let currentQueue = queue
        queueLock.unlock()
        
        await storage.setCodableArray(StorageKeys.eventQueue, value: currentQueue)
    }
    
    /// Start the periodic flush timer
    private func startFlushTimer() {
        stopFlushTimer() // Stop any existing timer
        
        flushTimer = Timer.scheduledTimer(withTimeInterval: config.flushInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.isOnline && !self.queue.isEmpty {
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