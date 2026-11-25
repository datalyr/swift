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
        // backpressure, which retries without burning the failure budget.
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
        #if DEBUG
        if let stubs = Self.protocolClassesForTesting {
            sessionConfig.protocolClasses = stubs + (sessionConfig.protocolClasses ?? [])
        }
        #endif

        self.session = URLSession(configuration: sessionConfig)
    }

    #if DEBUG
    /// Test support: URLProtocol stubs for clients created after this is set (this
    /// client's own session does not consult URLProtocol.registerClass).
    static var protocolClassesForTesting: [AnyClass]?
    #endif
    
    // MARK: - Event Sending
    
    /// Send a single event: ONE request, classified.
    ///
    /// The client no longer retries or sleeps inside a send. Waiting belongs to the queue,
    /// which keeps the event and paces every retry (backoff, Retry-After) so a server outage
    /// costs one probe per wait instead of a burst, and never moves a temporarily failing
    /// event toward the dead-letter store early. `response.disposition` says what the queue
    /// should do with the event.
    func sendEvent(_ payload: EventPayload) async -> HTTPResponse {
        // Pace, don't drop: wait for a rate-limit slot (backpressure) instead of
        // throwing, so a backlog burst is slowed down rather than dead-lettered (9.B.1).
        await waitForRateLimitSlot()
        debugLog("Sending event: \(payload.eventName)")

        let request: URLRequest
        do {
            request = try createRequest(for: payload)
        } catch {
            // The payload cannot be encoded: no retry will ever change that.
            errorLog("Event could not be encoded: \(payload.eventName)")
            return HTTPResponse(success: false, statusCode: 0, error: error, disposition: .rejected)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return HTTPResponse(success: false, statusCode: 0, error: HTTPError.invalidResponse,
                                    disposition: .retry(after: nil))
            }
            let status = httpResponse.statusCode
            let retryAfter = retryAfterSeconds(from: httpResponse)
            let disposition = Self.disposition(forStatus: status, retryAfter: retryAfter)
            switch disposition {
            case .delivered:
                debugLog("Event sent successfully: \(payload.eventName)")
                return HTTPResponse(success: true, statusCode: status, data: data, disposition: .delivered)
            case .refused where status == 404:
                // Ingest never answers 404: something in front of it sent this request elsewhere.
                errorLog("HTTP 404: the event endpoint was not found (a misroute in front of DATALYR ingest). Kept and retried.")
                return HTTPResponse(success: false, statusCode: status, data: data,
                                    error: HTTPError.httpError(status, "Endpoint not found"), disposition: disposition)
            case .refused:
                errorLog("HTTP \(status): Authentication failed. Check your API key and workspace ID.")
                return HTTPResponse(success: false, statusCode: status, data: data,
                                    error: HTTPError.authenticationFailed, disposition: disposition)
            default:
                errorLog("Event send failed: HTTP \(status)")
                return HTTPResponse(success: false, statusCode: status, data: data,
                                    error: HTTPError.httpError(status, String(data: data, encoding: .utf8)),
                                    disposition: disposition)
            }
        } catch {
            errorLog("Event send failed: \(error.localizedDescription)")
            return HTTPResponse(success: false, statusCode: 0, error: error, disposition: Self.disposition(forError: error))
        }
    }

    /// What an ingest answer means for the event (the server's answer contract,
    /// infra/cloudflare/ingest handleServerTrack):
    /// - any 2xx: stored (a duplicate event id also answers 200), never sent again;
    /// - 429 (Retry-After 1 or 60) and 408: backpressure, retried without spending an attempt;
    /// - 5xx, 503 (Retry-After 5 when the fault is the server's own): retried;
    /// - 401/403 (key refused) and 404 (never sent by ingest: a misroute): retried for
    ///   DatalyrEventQueue.refusalWindow, then dropped and counted;
    /// - any other 4xx (400 bad body or missing name/identity, 413 too large, 405, 415): this
    ///   exact request can never succeed, so the event is dropped at once and counted.
    static func disposition(forStatus status: Int, retryAfter: TimeInterval?) -> DeliveryDisposition {
        switch status {
        case 200..<300: return .delivered
        case 429, 408: return .throttled(after: retryAfter)
        // 404: ingest never answers it, so it comes from a misroute in front of ingest and
        // would otherwise wipe events on every phone at once.
        case 401, 403, 404: return .refused
        case 400..<500: return .rejected
        default: return .retry(after: retryAfter) // 5xx and anything unexpected (1xx/3xx)
        }
    }

    /// Transport errors are connectivity, never a verdict on the event: timeouts, lost or
    /// refused connections, DNS, TLS and cancelled requests are all retried. Only a request
    /// the client itself cannot build is final.
    static func disposition(forError error: Error) -> DeliveryDisposition {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL: return .rejected
            default: return .retry(after: nil)
            }
        }
        if let httpError = error as? HTTPError, case .invalidURL = httpError { return .rejected }
        return .retry(after: nil)
    }

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
    
    /// Longest wait a `Retry-After` header can ask for. Ingest sends 1, 5 or 60.
    static let maxRetryAfter: TimeInterval = 300

    /// Parse a `Retry-After` header (delta-seconds form). Clamped so a garbage header
    /// can't park an event for hours. Returns nil if absent or unreadable.
    private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), let seconds = Double(raw), seconds.isFinite else {
            return nil
        }
        return min(max(seconds, 0), Self.maxRetryAfter)
    }
    
    /// Apple privacy manifest: NSPrivacyTracking=true REQUIRES a non-empty
    /// NSPrivacyTrackingDomains, and iOS fails every request to a listed host unless the
    /// app's ATT status is authorized AT THE TIME OF THE REQUEST. The manifest lists ONLY
    /// tracking.datalyr.com. An event goes there only when it carries a real IDFA AND the
    /// live ATT status is authorized; everything else goes to the regular endpoint, which
    /// is never blocked. Same backend handler.
    static let trackingEndpoint = "https://tracking.datalyr.com/track"

    /// The all-zero IDFA iOS returns when tracking is not available. Not an identifier.
    static let zeroIDFA = "00000000-0000-0000-0000-000000000000"

    /// Source of the ATT status, read on EVERY send attempt (first send, retries and
    /// dead-letter replays), never the status cached when the event was built.
    /// Replaceable in tests.
    var attStatusProvider: () -> UInt = PlatformIntegrationManager.liveTrackingAuthorizationStatus

    /// A real IDFA on the payload: non-empty and not the all-zero value.
    static func carriesIDFA(_ payload: EventPayload) -> Bool {
        // eventData holds AnyCodable wrappers: read the wrapped value (a plain `as? String`
        // on the wrapper never matches, which sent every IDFA event to the regular endpoint).
        guard let idfa = payload.eventData?["idfa"]?.value as? String else { return false }
        return !idfa.isEmpty && idfa != zeroIDFA
    }

    func endpointFor(_ payload: EventPayload) -> String {
        return endpointFor(payload, attStatus: attStatusProvider())
    }

    func endpointFor(_ payload: EventPayload, attStatus: UInt) -> String {
        guard config.useServerTracking else { return endpoint }
        if attStatus == 3, DatalyrHTTPClient.carriesIDFA(payload) {
            return DatalyrHTTPClient.trackingEndpoint
        }
        return endpoint
    }

    /// Fields the SDK attaches only while ATT is authorized. When the live status is no
    /// longer authorized at send time (an event built or queued before the user turned
    /// tracking off), they are removed so the regular host never receives them, and the
    /// event's ATT fields are set to the live status so the server does not treat it as
    /// consented.
    static func removeTrackingOnlyFields(from properties: inout [String: Any], liveAttStatus: UInt) {
        properties.removeValue(forKey: "idfa")
        for key in AttributionData.appUserIdKeys { properties.removeValue(forKey: key) }
        let live = Int(liveAttStatus)
        if properties["att_status"] != nil { properties["att_status"] = live }
        if properties["advertiser_tracking_enabled"] != nil { properties["advertiser_tracking_enabled"] = false }
        if var advertiser = properties["advertiser_data"] as? [String: Any] {
            advertiser.removeValue(forKey: "idfa")
            if advertiser["att_status"] != nil { advertiser["att_status"] = live }
            if advertiser["tracking_authorized"] != nil { advertiser["tracking_authorized"] = false }
            properties["advertiser_data"] = advertiser
        }
    }

    /// Create the HTTP request for an event payload. Called on every send attempt.
    func createRequest(for payload: EventPayload) throws -> URLRequest {
        // One live read per attempt, so the host and the body always agree.
        let attStatus = attStatusProvider()
        guard let url = URL(string: endpointFor(payload, attStatus: attStatus)) else {
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
            var serverPayload = transformForServerAPI(payload)
            if attStatus != 3, var properties = serverPayload["properties"] as? [String: Any] {
                DatalyrHTTPClient.removeTrackingOnlyFields(from: &properties, liveAttStatus: attStatus)
                serverPayload["properties"] = properties
            }
            requestBody = try JSONSerialization.data(withJSONObject: serverPayload)
        } else {
            requestBody = try EventPayload.wireEncoder().encode(payload)
        }
        request.httpBody = requestBody
        
        if config.debug {
            // log the byte size, not the body — the payload carries PII
            // (email/phone/name in event properties) even in debug builds.
            debugLog("Request body: \(requestBody.count) bytes")
        }
        
        return request
    }
    
    /// Wait for a rate-limit slot using the thread-safe actor (bounded; never throws)
    private func waitForRateLimitSlot() async {
        await rateLimiter.waitForSlot()
    }
    
    /// Test-only: expose the HTTP-status retry classification so the suite can assert
    /// 429/408 are retryable without reaching the network. Mirrors the .httpError branch below.
    func isRetryableStatusForTest(_ code: Int) -> Bool {
        switch Self.disposition(forStatus: code, retryAfter: nil) {
        case .retry, .throttled: return true
        default: return false
        }
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
            // Ingest reads `properties.device_context` (and still accepts the pre-2.1.18
            // `properties.fingerprint` from older SDK builds).
            properties["device_context"] = ctxDict
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
