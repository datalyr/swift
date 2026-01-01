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

// MARK: - HTTP Client

/// HTTP client for sending events to Datalyr API
internal class DatalyrHTTPClient {
    private let endpoint: String
    private let config: HTTPClientConfig
    private let session: URLSession
    private var lastRequestTime: TimeInterval = 0
    private var requestCount: Int = 0
    private let rateLimitQueue = DispatchQueue(label: "com.datalyr.ratelimit")
    
    init(endpoint: String, config: HTTPClientConfig) {
        // Use server-side API if flag is set (default to true for v1.0.0)
        self.endpoint = config.useServerTracking 
            ? "https://api.datalyr.com" 
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
        return await sendWithRetry(payload, retryCount: 0)
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
    
    /// Send request with exponential backoff retry
    private func sendWithRetry(_ payload: EventPayload, retryCount: Int) async -> HTTPResponse {
        do {
            // Check rate limit
            try await checkRateLimit()
            
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
                return await sendWithRetry(payload, retryCount: retryCount + 1)
            }
            
            return HTTPResponse(success: false, statusCode: 0, error: error)
        }
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
        request.setValue("@datalyr/swift/1.1.0", forHTTPHeaderField: "User-Agent")
        
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
            debugLog("Request body: \(String(data: requestBody, encoding: .utf8) ?? "Invalid JSON")")
        }
        
        return request
    }
    
    /// Check rate limit
    private func checkRateLimit() async throws {
        try await rateLimitQueue.sync {
            let now = Date().timeIntervalSince1970
            
            if now - lastRequestTime < 60 {
                requestCount += 1
                if requestCount > 100 {
                    throw HTTPError.rateLimitExceeded
                }
            } else {
                requestCount = 1
                lastRequestTime = now
            }
        }
    }
    
    /// Determine if an error should trigger a retry
    private func shouldRetry(_ error: Error) -> Bool {
        if let httpError = error as? HTTPError {
            switch httpError {
            case .authenticationFailed, .rateLimitExceeded:
                return false
            case .httpError(let code, _):
                // Don't retry client errors (4xx), retry server errors (5xx)
                return code >= 500
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
    private func transformForServerAPI(_ payload: EventPayload) -> [String: Any] {
        var result: [String: Any] = [
            "event": payload.eventName,
            "timestamp": payload.timestamp ?? Date().toISOString()
        ]
        
        // Add user identifiers
        if let userId = payload.userId {
            result["userId"] = userId
        } else {
            result["userId"] = payload.visitorId
        }
        result["anonymousId"] = payload.visitorId
        
        // Add properties
        var properties: [String: Any] = payload.eventData ?? [:]
        properties["sessionId"] = payload.sessionId
        properties["source"] = payload.source ?? "ios_app"
        if let fingerprint = payload.fingerprintData {
            properties["fingerprint"] = fingerprint
        }
        result["properties"] = properties
        
        // Add context with explicit source
        var context: [String: Any] = [
            "library": "@datalyr/swift",
            "version": "1.1.0",
            "source": "mobile_app"  // Explicitly set source for iOS
        ]
        if let userProperties = payload.userProperties {
            context["userProperties"] = userProperties
        }
        result["context"] = context
        
        return result
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