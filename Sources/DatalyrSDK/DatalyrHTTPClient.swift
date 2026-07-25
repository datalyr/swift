import Foundation

// MARK: - HTTP Client Configuration

/// Configuration for HTTP client
internal struct HTTPClientConfig {
    let maxRetries: Int
    let retryDelay: TimeInterval
    let timeout: TimeInterval
    let apiKey: String // Required for server-side tracking
    let workspaceId: String? // Optional for backward compatibility
    let useServerTracking: Bool // Flag to use new server API
    let debug: Bool
    
    init(
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1.0,
        timeout: TimeInterval = 15.0,
        apiKey: String,
        workspaceId: String? = nil,
        useServerTracking: Bool = true,
        debug: Bool = false
    ) {
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.timeout = timeout
        self.apiKey = apiKey
        self.workspaceId = workspaceId
        self.useServerTracking = useServerTracking
        self.debug = debug
    }
}

// MARK: - Rate Limiter (Thread-Safe)

/// Actor-based sliding-window rate limiter with BACKPRESSURE, not drop (9.B.1).
/// The old fixed-window version THREW `rateLimitExceeded` past 100 requests/min; since
/// shouldRetry() classified that as non-retryable, every rate-limited send failed on its
/// first attempt, the queue burned one of its 3 retries per pass, and a >100-event backlog
/// draining in one burst (e.g. after airplane mode) silently dead-lettered revenue events.
/// Now callers WAIT until the window has room, so a burst is paced out instead of lost —
/// mirrors the React Native SDK's enforceRateLimit() fix.
/// (internal, not private, so tests can exercise the pacing with a tiny window.)
internal actor RateLimiter {
    /// Timestamps of recent sends, oldest first (appends are in time order).
    private var requestTimestamps: [TimeInterval] = []
    private let maxRequestsPerWindow: Int
    private let window: TimeInterval

    init(maxRequestsPerWindow: Int = 100, window: TimeInterval = 60) {
        self.maxRequestsPerWindow = maxRequestsPerWindow
        self.window = window
    }

    /// Wait (bounded) until the sliding window has room, then claim a slot. Never throws.
    func waitForSlot() async {
        // Bound the total wait so a send can never hang forever: past the deadline we
        // proceed anyway and let the server arbitrate — its 429 is handled as transient
        // backpressure (FSR-31), which retries without burning the failure budget.
        let deadline = Date().timeIntervalSince1970 + window * 2

        while true {
            let now = Date().timeIntervalSince1970
            requestTimestamps.removeAll { now - $0 >= window }

            if requestTimestamps.count < maxRequestsPerWindow || now >= deadline {
                requestTimestamps.append(now)
                return
            }

            // The oldest survived the prune, so (window - (now - oldest)) is in (0, window].
            // +0.05 margin guarantees it exits the window on the next pass; the floor keeps
            // the loop from busy-spinning, and the cap defends against a corrupted future
            // timestamp WITHOUT clipping the margin. Task.sleep suspends the actor (it does
            // not block it), so concurrent waiters interleave and re-check on wake.
            let oldest = requestTimestamps[0]
            let wait = min(max(window - (now - oldest) + 0.05, 0.05), window + 0.1)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}

// MARK: - HTTP Client

/// HTTP client for sending events to Datalyr API
internal class DatalyrHTTPClient {
    private let endpoint: String
    private let config: HTTPClientConfig
    private let session: URLSession
    private let rateLimiter = RateLimiter()
    
    init(endpoint: String, config: HTTPClientConfig) {
        // Use server-side API if flag is set (default to true for v1.0.0)
        self.endpoint = config.useServerTracking
            ? (endpoint.isEmpty ? "https://ingest.datalyr.com/track" : endpoint)
            : endpoint
        self.config = config
        
        // Create URLSession with custom configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout * 2
        sessionConfig.waitsForConnectivity = true
        sessionConfig.allowsCellularAccess = true
        
        self.session = URLSession(configuration: sessionConfig)
    }
    
    // MARK: - Event Sending
    
    /// Send a single event with retry logic
    func sendEvent(_ payload: EventPayload) async -> HTTPResponse {
        return await sendWithRetry(payload, retryCount: 0, throttleCount: 0)
    }

    /// Max consecutive 429/408 backpressure waits before giving up within a single send.
    /// These do NOT count against the normal retryCount (a 429 is backpressure, not failure —
    /// FSR-31), so this separate cap prevents an unbounded loop under sustained throttling.
    private static let maxThrottleWaits = 5
    
    /// Send multiple events in a batch
    func sendBatch(_ payloads: [EventPayload]) async -> [HTTPResponse] {
        // For now, send events individually
        // In production, you might want to implement true batching
        return await withTaskGroup(of: HTTPResponse.self) { group in
            for payload in payloads {
                group.addTask {
                    await self.sendEvent(payload)
                }
            }
            
            var responses: [HTTPResponse] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }
    }
    
    // MARK: - Private Methods
    
    /// Send request with exponential backoff retry.
    /// `retryCount` counts genuine failures (5xx, network) against config.maxRetries.
    /// `throttleCount` counts 429/408 backpressure waits separately (FSR-31) so sustained
    /// throttling honors Retry-After without burning the failure budget toward dead-letter.
    private func sendWithRetry(_ payload: EventPayload, retryCount: Int, throttleCount: Int) async -> HTTPResponse {
        do {
            // Pace, don't drop: wait for a rate-limit slot (backpressure) instead of
            // throwing, so a backlog burst is slowed down rather than dead-lettered (9.B.1).
            await waitForRateLimitSlot()

            debugLog("Sending event: \(payload.eventName) (attempt \(retryCount + 1))")

            // Create request
            let request = try createRequest(for: payload)

            // Send request
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }

            // Check response status
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                debugLog("Event sent successfully: \(payload.eventName)")
                return HTTPResponse(success: true, statusCode: httpResponse.statusCode, data: data)
            } else if httpResponse.statusCode == 401 {
                let errorMessage = "HTTP 401: Authentication failed. Check your API key and workspace ID."
                errorLog(errorMessage)
                return HTTPResponse(success: false, statusCode: httpResponse.statusCode, error: HTTPError.authenticationFailed)
            } else if httpResponse.statusCode == 429 || httpResponse.statusCode == 408 {
                // FSR-31: 429 (ingest sends Retry-After:1) / 408 are TRANSIENT backpressure, not
                // permanent client errors. Honor Retry-After and retry WITHOUT counting it as a
                // failure, so a workspace-wide throttle burst doesn't dead-letter events.
                guard throttleCount < DatalyrHTTPClient.maxThrottleWaits else {
                    debugLog("Throttle persisted past \(DatalyrHTTPClient.maxThrottleWaits) waits; surfacing \(httpResponse.statusCode)")
                    return HTTPResponse(success: false, statusCode: httpResponse.statusCode,
                                        error: HTTPError.httpError(httpResponse.statusCode, "rate limited"))
                }
                let retryAfter = retryAfterSeconds(from: httpResponse) ?? calculateRetryDelay(throttleCount)
                debugLog("HTTP \(httpResponse.statusCode) throttled; honoring Retry-After \(retryAfter)s (wait \(throttleCount + 1))")
                try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                return await sendWithRetry(payload, retryCount: retryCount, throttleCount: throttleCount + 1)
            } else {
                throw HTTPError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8))
            }

        } catch {
            errorLog("Event send failed (attempt \(retryCount + 1)): \(error.localizedDescription)")

            // Check if we should retry
            if retryCount < config.maxRetries && shouldRetry(error) {
                let delay = calculateRetryDelay(retryCount)
                debugLog("Retrying in \(delay)s...")

                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return await sendWithRetry(payload, retryCount: retryCount + 1, throttleCount: throttleCount)
            }

            return HTTPResponse(success: false, statusCode: 0, error: error)
        }
    }

    /// Parse a `Retry-After` header (delta-seconds form; ingest sends "1"). Clamped to a sane
    /// ceiling so a hostile/garbage header can't park an event for minutes. Returns nil if absent.
    private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), let seconds = Double(raw) else {
            return nil
        }
        return min(max(seconds, 0), 30)
    }
    
    /// Create HTTP request for event payload
    private func createRequest(for payload: EventPayload) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw HTTPError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        
        // Set headers
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DatalyrVersion.userAgent, forHTTPHeaderField: "User-Agent")
        
        // Server-side tracking uses X-API-Key header
        if config.useServerTracking {
            request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        } else {
            // Legacy client-side tracking
            let authToken = config.apiKey.isEmpty ? (config.workspaceId ?? "") : config.apiKey
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            if !config.apiKey.isEmpty {
                request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
                request.setValue(config.apiKey, forHTTPHeaderField: "X-Datalyr-API-Key")
            }
        }
        
        // Transform payload for server-side API if needed
        let requestBody: Data
        if config.useServerTracking {
            let serverPayload = transformForServerAPI(payload)
            requestBody = try JSONSerialization.data(withJSONObject: serverPayload)
        } else {
            requestBody = try JSONEncoder().encode(payload)
        }
        request.httpBody = requestBody
        
        if config.debug {
            // IOS-19: log the byte size, not the body — the payload carries PII
            // (email/phone/name in event properties) even in debug builds.
            debugLog("Request body: \(requestBody.count) bytes")
        }
        
        return request
    }
    
    /// Wait for a rate-limit slot using the thread-safe actor (bounded; never throws)
    private func waitForRateLimitSlot() async {
        await rateLimiter.waitForSlot()
    }
    
    /// Test-only: expose the HTTP-status retry classification (FSR-31) so the suite can assert
    /// 429/408 are retryable without reaching the network. Mirrors the .httpError branch below.
    func isRetryableStatusForTest(_ code: Int) -> Bool {
        return shouldRetry(HTTPError.httpError(code, nil))
    }

    /// Determine if an error should trigger a retry
    private func shouldRetry(_ error: Error) -> Bool {
        if let httpError = error as? HTTPError {
            switch httpError {
            case .authenticationFailed, .rateLimitExceeded:
                // .rateLimitExceeded is no longer thrown anywhere — the client-side limiter
                // now waits for a slot instead of throwing (9.B.1). The case is kept in the
                // enum for exhaustiveness/compatibility; classified non-retryable if it ever
                // resurfaces so it can't loop.
                return false
            case .httpError(let code, _):
                // Retry server errors (5xx) and transient throttling/timeout (429, 408).
                // Other 4xx are permanent client errors and won't improve on retry (FSR-31).
                return code >= 500 || code == 429 || code == 408
            default:
                return true
            }
        }
        
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        
        return false
    }
    
    /// Calculate exponential backoff delay
    private func calculateRetryDelay(_ retryCount: Int) -> TimeInterval {
        let baseDelay = config.retryDelay
        let exponentialDelay = pow(2.0, Double(retryCount)) * baseDelay
        let jitter = Double.random(in: 0...1) // Add jitter to prevent thundering herd
        return min(exponentialDelay + jitter, 30.0) // Cap at 30 seconds
    }
    
    // MARK: - Utility Methods
    
    /// Test connectivity to the endpoint
    func testConnection() async -> Bool {
        let testPayload = EventPayload(
            workspaceId: "test",
            visitorId: "test",
            anonymousId: "test",
            sessionId: "test",
            eventId: "test",
            eventName: "connection_test"
        )
        
        let response = await sendEvent(testPayload)
        return response.success
    }
    
    /// Update endpoint URL
    func updateEndpoint(_ newEndpoint: String) {
        // Note: This would require recreating the client in practice
        debugLog("Endpoint update requested: \(newEndpoint)")
    }
    
    /// Transform payload for server-side API format
    /// (internal, not private, so the wire-contract test can assert the exact shape.)
    func transformForServerAPI(_ payload: EventPayload) -> [String: Any] {
        var result: [String: Any] = [
            "event": payload.eventName,
            "eventId": payload.eventId,
            "timestamp": payload.timestamp ?? Date().toISOString()
        ]

        // Add user identifiers
        if let userId = payload.userId {
            result["userId"] = userId
        }
        result["anonymousId"] = payload.anonymousId ?? payload.visitorId

        // Add properties (sanitized for JSON compatibility)
        var properties: [String: Any] = sanitizeForJSON(payload.eventData ?? [:])
        properties["sessionId"] = payload.sessionId
        properties["source"] = payload.source ?? "mobile_app"
        if let deviceCtx = payload.deviceContext,
           let ctxData = try? JSONEncoder().encode(deviceCtx),
           let ctxDict = try? JSONSerialization.jsonObject(with: ctxData) as? [String: Any] {
            properties["fingerprint"] = ctxDict
        }
        result["properties"] = properties

        // Add context with explicit source. session_id MUST live in context — the
        // ingest server-track handler reads the session id from `context.session_id`
        // (cloudflare/ingest/index.js handleServerTrack), NOT from properties; without
        // it here, ingest discards the SDK's 30-min session and synthesizes its own
        // hour-bucketed session id for every iOS event.
        var context: [String: Any] = [
            "library": DatalyrVersion.libraryName,
            "version": DatalyrVersion.current,
            "source": "mobile_app",
            "session_id": payload.sessionId
        ]
        if let userProperties = payload.userProperties {
            context["userProperties"] = sanitizeForJSON(userProperties)
        }
        result["context"] = context

        return result
    }

    /// Recursively sanitize a dictionary to only contain JSON-compatible types
    private func sanitizeForJSON(_ dict: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            if let sanitized = sanitizeValue(value) {
                result[key] = sanitized
            }
        }
        return result
    }

    /// Sanitize a single value for JSON compatibility
    private func sanitizeValue(_ value: Any) -> Any? {
        // Unwrap AnyCodable
        if let anyCodable = value as? AnyCodable {
            return sanitizeValue(anyCodable.value)
        }
        // Primitives
        if let v = value as? String { return v }
        if let v = value as? Int { return v }
        // UInt is NOT caught by `as? Int` in Swift — without this it falls through to the
        // "\(value)" last-resort below and ships as a STRING. att_status (ATT status 0-3,
        // a UInt) was being sent as "0"/"3" instead of a number. Keep it numeric.
        if let v = value as? UInt { return Int(exactly: v) ?? Int(v & UInt(Int.max)) }
        if let v = value as? Double { return v }
        if let v = value as? Bool { return v }
        if let v = value as? Float { return Double(v) }
        // Collections
        if let dict = value as? [String: Any] {
            return sanitizeForJSON(dict)
        }
        if let arr = value as? [Any] {
            return arr.compactMap { sanitizeValue($0) }
        }
        // Null
        if value is NSNull { return nil }
        // Optional nil check
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional && mirror.children.isEmpty {
            return nil
        }
        // Last resort — string conversion
        let str = "\(value)"
        if str == "nil" || str == "Optional(nil)" { return nil }
        return str
    }
}

// Date extension for ISO string formatting
extension Date {
    func toISOString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}

// MARK: - HTTP Errors

/// HTTP client specific errors
internal enum HTTPError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case authenticationFailed
    case rateLimitExceeded
    case httpError(Int, String?)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response"
        case .authenticationFailed:
            return "Authentication failed"
        case .rateLimitExceeded:
            return "Rate limit exceeded: max 100 requests per minute"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message ?? "Unknown error")"
        }
    }
}

// MARK: - DispatchQueue Extension

extension DispatchQueue {
    func sync<T>(_ work: () throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            self.sync {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
