import Foundation
import Network

// MARK: - Queue Configuration

/// Configuration for event queue
internal struct QueueConfig {
    let maxQueueSize: Int
    let batchSize: Int
    let flushInterval: TimeInterval
    /// Failed attempts (5xx, timeout, network; not 429/408) after which an event moves to
    /// the dead-letter store, where it is kept and replayed on the next launch.
    let maxRetryCount: Int
    /// First wait after a failed attempt; doubles per consecutive failure up to maxBackoff.
    let retryBaseDelay: TimeInterval

    /// The fewest attempts the SDK gives an event before dead-lettering it. With the
    /// doubling backoff (1 s … 300 s) ten attempts span about 8 to 10 minutes, so a short
    /// server outage loses nothing. DatalyrConfig.maxRetries can only raise it.
    static let minTransientAttempts = 10

    init(
        maxQueueSize: Int = 1000, // TR-05: was 100 — an offline period producing >100 events lost everything beyond the newest 100
        batchSize: Int = 10,
        flushInterval: TimeInterval = 30.0,
        maxRetryCount: Int = QueueConfig.minTransientAttempts,
        retryBaseDelay: TimeInterval = 1.0
    ) {
        self.maxQueueSize = maxQueueSize
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.maxRetryCount = maxRetryCount
        self.retryBaseDelay = retryBaseDelay
    }
}

// MARK: - Event Queue

/// Event queue for offline storage and batching
internal class DatalyrEventQueue {
    private let httpClient: DatalyrHTTPClient
    // var (was let): updateConfig() now actually applies the new config (FSR-89). Mutated only
    // under queueLock so concurrent reads on the processing path see a consistent value.
    private var config: QueueConfig
    private let storage = DatalyrStorage.shared
    private var queue: [QueuedEvent] = []
    // DispatchSourceTimer (not Timer): the queue initializes on a cooperative-pool Task with
    // no running RunLoop, so a Timer.scheduledTimer registered there would NEVER fire. A
    // dispatch-source timer on processingQueue fires regardless of any run loop. (IOS-6)
    private var flushTimer: DispatchSourceTimer?
    private var _isProcessing = false
    private var _isOnline = true

    // Drives _isOnline from real connectivity so the offline queue actually holds events
    // during an outage instead of burning the retry budget toward dead-letter. (IOS-15)
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.datalyr.network-monitor")

    /// Called (off the lock) whenever an event is moved to the dead-letter store — retry
    /// budget exhausted or evicted by queue overflow. The SDK forwards it to
    /// `DatalyrSDKDelegate.datalyrDidFailToSendEvent`.
    var onDeadLetter: ((QueuedEvent, Error) -> Void)?

    // FX-047 retry gate: after a failed attempt nothing is sent before `_retryNotBefore`
    // (seconds since 1970). `_consecutiveFailures` drives the doubling backoff and is reset
    // by any delivered event. Both under queueLock.
    private var _retryNotBefore: TimeInterval = 0
    private var _consecutiveFailures = 0
    /// Events dropped for good, by reason (persisted; see QueueStats.droppedEvents).
    private var _dropCounts: [String: Int] = [:]

    /// Longest wait between attempts.
    static let maxBackoff: TimeInterval = 300
    /// How long an event whose key the server refuses (401/403) is kept and retried.
    static let authRefusalWindow: TimeInterval = 600
    /// Dead-letter store capacity.
    static let maxDeadLetter = 100

    /// Drop reasons (keys of QueueStats.droppedEventsByReason).
    enum DropReason: String, CaseIterable {
        case rejected            // final 4xx or an unencodable payload
        case authRefused = "auth_refused"           // 401/403 for longer than authRefusalWindow
        case deadLetterFull = "dead_letter_full"    // dead-letter store over maxDeadLetter
        case deadLetterExpired = "dead_letter_expired" // replayed maxDeadLetterReplays times or older than 7 days
    }

    /// Clock (seconds since 1970). Tests replace it to move time without waiting.
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    /// Wakes the queue `delay` seconds from now to retry. Tests replace it.
    lazy var scheduleRetry: (TimeInterval) -> Void = { [weak self] delay in
        self?.processingQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            Task { await self.processQueue() }
        }
    }

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
        var evicted: QueuedEvent? = nil

        // Add to queue under lock
        let shouldFlush: Bool = queueLock.withLock {
            // Check queue size limit
            if queue.count >= config.maxQueueSize {
                // TR-05: an overflow used to removeFirst() (the OLDEST event — i.e. the head of
                // the offline backlog, often a purchase) and silently drop it. Evict the oldest
                // NON-critical event instead (keep revenue/conversion events), and dead-letter
                // the evicted one so it's replayed on the next launch rather than lost forever.
                // All-critical → evict the oldest (still dead-lettered, capped at 100).
                let idx = queue.firstIndex(where: { !Self.isCriticalEvent($0) }) ?? 0
                let removed = queue.remove(at: idx)
                evicted = removed
                debugLog("Queue full (\(config.maxQueueSize)); evicting \(removed.payload.eventName) → dead-letter")
            }

            queue.append(queuedEvent)
            debugLog("Event queued: \(payload.eventName) (queue size: \(queue.count))")

            // Check if we should flush (while still holding lock)
            return _isOnline && !_isProcessing
        }

        // Dead-letter the evicted event (outside the lock — deadLetter is async).
        if let evicted = evicted {
            await deadLetter(evicted, reason: DatalyrQueueError.evicted(queueSize: config.maxQueueSize))
        }

        // Persist to storage (outside lock)
        await persistQueue()

        // Try to flush immediately if online
        if shouldFlush {
            await processQueue()
        }
    }

    /// TR-05: revenue/conversion events protected from queue-overflow eviction — the offline
    /// queue exists precisely to hold these, so evict cheaper analytics events first. Matches
    /// on the canonical revenue event names or any value/revenue-bearing eventData.
    private static func isCriticalEvent(_ event: QueuedEvent) -> Bool {
        let name = event.payload.eventName.lowercased()
        // Track-3 review P2: `app_install` carries no value/revenue key, so it was classified
        // NON-critical and could be evicted from a large first-launch offline backlog (then
        // pushed out of deadLetter's suffix(100)) — permanently losing install attribution, the
        // exact loss TR-05/TR-21 target. Protect the install family alongside revenue events.
        if name.contains("purchase") || name.contains("subscribe") || name.contains("checkout") || name.contains("install") {
            return true
        }
        if let data = event.payload.eventData {
            for key in ["value", "revenue", "amount", "price"] where data[key] != nil {
                return true
            }
        }
        return false
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
                oldestEventAge: oldestEventAge,
                droppedEventsByReason: _dropCounts
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
        // FSR-89: actually APPLY newConfig — the old body ignored its argument and just
        // restarted the timer with the SAME (old) interval, so flush interval / batch size /
        // retry budget never changed. Assign under the lock so the processing path sees it
        // consistently, then restart the timer to pick up the new flush interval.
        queueLock.withLock { config = newConfig }

        stopFlushTimer()
        startFlushTimer()

        debugLog("Queue configuration updated")
    }
    
    /// Destroy the queue (cleanup)
    func destroy() {
        stopFlushTimer()
        pathMonitor.cancel()

        // Save current queue state
        Task {
            await persistQueue()
        }

        debugLog("Event queue destroyed")
    }
    
    // MARK: - Private Methods

    /// Dead-letter replay bounds (kept in lockstep with the RN SDK's event-queue.ts).
    static let maxDeadLetterReplays = 3
    static let maxDeadLetterAge: TimeInterval = 7 * 24 * 60 * 60

    /// Initialize the queue by loading persisted events
    private func initializeQueue() async {
        var loaded: [String: Int] = [:]
        for reason in DropReason.allCases {
            if let n = await storage.getDouble(Self.dropCountKey(reason)), n > 0 { loaded[reason.rawValue] = Int(n) }
        }
        queueLock.withLock {
            for (k, v) in loaded { _dropCounts[k, default: 0] += v }
        }

        if let persistedQueue = await storage.getCodableArray(StorageKeys.eventQueue, type: QueuedEvent.self) {
            let count = queueLock.withLock {
                // FSR-84: PREPEND the persisted backlog instead of overwriting `queue`. The
                // queue's init Task races SDK.initialize, which can enqueue events (pre-init
                // backlog, app_install, session_start) before this load runs; a wholesale
                // `queue = persistedQueue` would silently drop those — and the next persistQueue()
                // would make the loss permanent. Merge preserves both, persisted-first (oldest).
                queue = persistedQueue + queue
                return queue.count
            }
            debugLog("Loaded \(count) events from storage")
        }

        // FSR-88: replay the dead-letter store ONCE per launch. deadLetter() previously only
        // wrote to StorageKeys.deadLetterQueue and nothing ever read it ("recoverable for
        // replay" was false) — so an event that exhausted 3 retries (transient outage / temporary
        // 401) was permanently lost. Re-enqueue with retryCount reset and clear the store, giving
        // failed revenue/conversion events one fresh delivery attempt on the next app start.
        // Bounded (mirrors the RN SDK's replayDeadLetter): each replay bumps replayCount, and
        // entries that already replayed maxDeadLetterReplays times or are older than
        // maxDeadLetterAge are dropped for good — a permanently-rejected payload (400/413)
        // would otherwise loop through dead-letter → replay → dead-letter on every launch.
        if let dead = await storage.getCodableArray(StorageKeys.deadLetterQueue, type: QueuedEvent.self), !dead.isEmpty {
            let now = Date().timeIntervalSince1970
            var replays: [QueuedEvent] = []
            var dropped = 0
            for event in dead {
                let age = now - event.timestamp
                if event.replayCount >= Self.maxDeadLetterReplays || age > Self.maxDeadLetterAge {
                    dropped += 1
                    continue
                }
                replays.append(QueuedEvent(payload: event.payload, timestamp: event.timestamp,
                                           retryCount: 0, replayCount: event.replayCount + 1))
            }
            if !replays.isEmpty {
                queueLock.withLock { queue = replays + queue }
            }
            await storage.removeValue(StorageKeys.deadLetterQueue)
            await persistQueue()
            if dropped > 0 {
                await countDrop(.deadLetterExpired, dropped)
                errorLog("Dropped \(dropped) undeliverable dead-letter event(s) (replayed \(Self.maxDeadLetterReplays)× or older than 7 days)")
            }
            debugLog("Replayed \(replays.count) dead-letter event(s) for one more delivery attempt")
        }

        startFlushTimer()
        startNetworkMonitor()
    }

    /// Drive online/offline from real network reachability (IOS-15).
    private func startNetworkMonitor() {
        // Don't run a live reachability monitor under XCTest — tests drive online/offline
        // explicitly via setOnlineStatus(), and a monitor flipping the flag back to online
        // would non-deterministically trigger real network sends mid-test.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.setOnlineStatus(path.status == .satisfied)
        }
        pathMonitor.start(queue: monitorQueue)
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

        // Drain in batches until the queue is empty or a batch makes no forward progress.
        // processQueueInternal sends only one batchSize-sized batch; without this loop a
        // manual flush() of a 100-event backlog would send just the first 10 (IOS-13).
        // Progress check (a batch must actually remove events) prevents a busy-loop when
        // events are failing-and-requeued (transient outage) — successes and dead-letters both
        // remove events, retried-but-not-dropped events don't, so we stop and let the timer
        // retry. Counts removals directly rather than comparing before/after queue length:
        // an enqueue landing mid-batch used to make `after >= before` true and stop the drain
        // even though the batch had delivered fine.
        while true {
            let current = now()
            let hasWork = queueLock.withLock { _isOnline && !queue.isEmpty && current >= _retryNotBefore }
            guard hasWork else { break }
            let removed = await processQueueInternal()
            if removed == 0 { break }
        }

        queueLock.withLock { _isProcessing = false }
    }
    
    /// Internal queue processing logic. Returns the number of events removed from the queue
    /// by this batch (delivered, dropped or dead-lettered).
    ///
    /// FX-047: an event leaves the queue only when the server stored it (2xx), refused it
    /// as final (4xx other than 401/403/408/429: dropped and counted), kept refusing its key
    /// past authRefusalWindow (dropped and counted), or failed maxRetryCount attempts
    /// (moved to the dead-letter store, replayed next launch). The first attempt that does
    /// not deliver ends the batch and closes the gate until the backoff or Retry-After has
    /// passed: one probe per wait while the server is down, never a burst. Every retry
    /// resends the same payload, so the same event id.
    @discardableResult
    private func processQueueInternal() async -> Int {
        // Get events to process (up to batch size)
        let eventsToProcess: [QueuedEvent] = queueLock.withLock {
            let batchSize = min(config.batchSize, queue.count)
            return Array(queue.prefix(batchSize))
        }

        var removed: [QueuedEvent] = []
        var updated: QueuedEvent? = nil
        var waitHint: TimeInterval? = nil
        var countsAsFailure = false
        var paused = false

        for queuedEvent in eventsToProcess {
            let response = await httpClient.sendEvent(queuedEvent.payload)

            switch response.disposition {
            case .delivered:
                debugLog("Event sent successfully: \(queuedEvent.payload.eventName)")
                removed.append(queuedEvent)
                queueLock.withLock { _consecutiveFailures = 0 }
                continue

            case .rejected:
                errorLog("Event refused by the server (HTTP \(response.statusCode)); dropped: \(queuedEvent.payload.eventName)")
                await countDrop(.rejected)
                removed.append(queuedEvent)
                onDeadLetter?(queuedEvent, response.error ?? DatalyrQueueError.maxRetriesExceeded(statusCode: response.statusCode, retries: queuedEvent.retryCount + 1))
                continue

            case .authRefused:
                var event = queuedEvent
                let since = event.authRefusedSince ?? now()
                event.authRefusedSince = since
                if now() - since >= Self.authRefusalWindow {
                    errorLog("Event key refused (HTTP \(response.statusCode)) for \(Int(Self.authRefusalWindow / 60)) minutes; dropped: \(queuedEvent.payload.eventName)")
                    await countDrop(.authRefused)
                    removed.append(queuedEvent)
                    onDeadLetter?(queuedEvent, response.error ?? HTTPError.authenticationFailed)
                    continue
                }
                updated = event
                countsAsFailure = true

            case .throttled(let after):
                // Backpressure, not failure (FSR-31): spends no attempt.
                waitHint = after
                countsAsFailure = after == nil

            case .retry(let after):
                var event = queuedEvent
                event.retryCount += 1
                waitHint = after
                countsAsFailure = true
                if event.retryCount >= config.maxRetryCount {
                    errorLog("Event failed \(config.maxRetryCount) attempts; moved to dead-letter: \(queuedEvent.payload.eventName)")
                    let reason = response.error ?? DatalyrQueueError.maxRetriesExceeded(statusCode: response.statusCode, retries: config.maxRetryCount)
                    await deadLetter(event, reason: reason)
                    removed.append(queuedEvent)
                } else {
                    debugLog("Event failed, kept for retry: \(queuedEvent.payload.eventName) (attempt \(event.retryCount))")
                    updated = event
                }
            }
            paused = true
            break // not delivered: stop this batch and wait
        }

        // Apply the outcome under the lock.
        let delay: TimeInterval? = queueLock.withLock {
            if let updated = updated, let index = queue.firstIndex(where: { $0.payload.eventId == updated.payload.eventId }) {
                queue[index] = updated
            }
            let ids = Set(removed.map { $0.payload.eventId })
            if !ids.isEmpty { queue.removeAll { ids.contains($0.payload.eventId) } }
            guard paused else { return nil }
            if countsAsFailure { _consecutiveFailures += 1 }
            let wait = waitHint.map { min(max($0, 0), Self.maxBackoff) }
                ?? Self.backoff(failures: max(_consecutiveFailures, 1), base: config.retryBaseDelay)
            _retryNotBefore = now() + wait
            return wait
        }

        if !removed.isEmpty || updated != nil {
            await persistQueue()
        }
        if let delay = delay {
            debugLog("Delivery paused for \(String(format: "%.1f", delay))s")
            scheduleRetry(delay)
        }
        return removed.count
    }

    /// Doubling backoff from `base`, capped at maxBackoff, plus up to 25% jitter so many
    /// devices coming back from one outage do not retry in step.
    static func backoff(failures: Int, base: TimeInterval) -> TimeInterval {
        let exponent = Double(min(max(failures - 1, 0), 30))
        let raw = min(max(base, 0.1) * pow(2.0, exponent), maxBackoff)
        return min(raw * (1 + Double.random(in: 0...0.25)), maxBackoff)
    }

    /// Earliest time the next attempt may go out (seconds since 1970). Tests read it.
    var retryNotBefore: TimeInterval { queueLock.withLock { _retryNotBefore } }

    static func dropCountKey(_ reason: DropReason) -> String { "dropped_events_\(reason.rawValue)" }

    /// Count events dropped for good, in memory and in storage.
    private func countDrop(_ reason: DropReason, _ n: Int = 1) async {
        guard n > 0 else { return }
        let total: Int = queueLock.withLock {
            _dropCounts[reason.rawValue, default: 0] += n
            return _dropCounts[reason.rawValue] ?? n
        }
        await storage.setDouble(Self.dropCountKey(reason), value: Double(total))
    }

    /// Persist queue to storage
    private func persistQueue() async {
        let currentQueue = queueLock.withLock { queue }
        await storage.setCodableArray(StorageKeys.eventQueue, value: currentQueue)
    }

    /// Park a retry-exhausted event in a capped dead-letter store instead of silently
    /// dropping it — visible (errorLog above) and replayed once on the next launch by
    /// initializeQueue() (FSR-88), so a transient outage that beats the retry budget gets
    /// another delivery attempt rather than being lost.
    private func deadLetter(_ event: QueuedEvent, reason: Error) async {
        var dl = (await storage.getCodableArray(StorageKeys.deadLetterQueue, type: QueuedEvent.self)) ?? []
        dl.append(event)
        // Over capacity: drop the oldest non-critical entry first (a purchase or install
        // outlives analytics events), and count every drop (FX-047).
        var overflow = 0
        while dl.count > Self.maxDeadLetter {
            let idx = dl.firstIndex(where: { !Self.isCriticalEvent($0) }) ?? 0
            dl.remove(at: idx)
            overflow += 1
        }
        await storage.setCodableArray(StorageKeys.deadLetterQueue, value: dl)
        if overflow > 0 {
            errorLog("Dead-letter store full (\(Self.maxDeadLetter)); dropped \(overflow) event(s)")
            await countDrop(.deadLetterFull, overflow)
        }
        onDeadLetter?(event, reason)
    }
    
    /// Start the periodic flush timer (dispatch-source based so it fires without a RunLoop).
    private func startFlushTimer() {
        stopFlushTimer() // Stop any existing timer

        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + config.flushInterval,
                       repeating: config.flushInterval,
                       leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
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
        timer.resume()
        flushTimer = timer

        debugLog("Flush timer started with interval: \(config.flushInterval)s")
    }

    /// Stop the flush timer
    private func stopFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
        debugLog("Flush timer stopped")
    }
}

// MARK: - Queue Errors

/// Reasons an event lands in the dead-letter store, surfaced through
/// `DatalyrSDKDelegate.datalyrDidFailToSendEvent` as `.networkError`.
public enum DatalyrQueueError: LocalizedError {
    case maxRetriesExceeded(statusCode: Int, retries: Int)
    case evicted(queueSize: Int)

    public var errorDescription: String? {
        switch self {
        case .maxRetriesExceeded(let status, let retries):
            return "Event exceeded \(retries) delivery attempts (last status \(status)); moved to dead-letter"
        case .evicted(let size):
            return "Event evicted from a full offline queue (\(size)); moved to dead-letter"
        }
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