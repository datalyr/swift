import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Auto Events Tracking Delegate

/// Protocol for auto events to communicate with the main SDK.
/// Screen view events are now fired by the SDK's `screen()` method directly;
/// the auto-events manager only uses `trackEvent` for lifecycle events
/// (session_start, session_end, screen_end, app lifecycle, etc.).
internal protocol AutoEventsTrackingDelegate: AnyObject {
    func trackEvent(_ eventName: String, properties: EventData?)
}

// MARK: - Auto Events Manager

/// Manages automatic event tracking for sessions, screen views, and app lifecycle
internal class AutoEventsManager {
    private weak var trackingDelegate: AutoEventsTrackingDelegate?
    private let config: AutoEventConfig
    private let storage = DatalyrStorage.shared
    
    // Session tracking
    private var currentSession: SessionData?
    private var sessionTimer: Timer?
    private var lastActivityTime = Date()
    private var isInitialized = false
    
    // Screen tracking
    private var currentScreen: String?
    private var screenStartTime: Date?
    
    // App version tracking
    private var lastTrackedVersion: String?
    
    init(trackingDelegate: AutoEventsTrackingDelegate, config: AutoEventConfig) {
        self.trackingDelegate = trackingDelegate
        self.config = config
    }
    
    // MARK: - Initialization
    
    /// Initialize auto events tracking
    func initialize() async {
        debugLog("Initializing auto events manager...")

        // Load last tracked version for update detection
        lastTrackedVersion = await storage.getString(StorageKeys.lastAppVersion)

        // Initialize session tracking FIRST (before observers)
        if config.trackSessions {
            await initializeSessionTracking()
        }

        // App update tracking removed — not needed for attribution analytics

        isInitialized = true

        // Set up lifecycle observers AFTER init is complete
        // so appDidBecomeActive doesn't fire duplicate session_start
        setupAppLifecycleObservers()

        debugLog("Auto events manager initialized")
    }
    
    // MARK: - Session Tracking
    
    /// Initialize session tracking
    private func initializeSessionTracking() async {
        let sessionId = await getOrCreateSessionId()
        let appVersion = getAppVersion()
        #if canImport(UIKit)
        let osVersion = UIDevice.current.systemVersion
        #else
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        
        currentSession = SessionData(
            sessionId: sessionId,
            startTime: Date(),
            appVersion: appVersion,
            osVersion: osVersion
        )
        
        // Track session start
        trackingDelegate?.trackEvent("session_start", properties: [
            "session_id": sessionId,
            "app_version": appVersion,
            "os_version": osVersion,
            "platform": "ios"
        ])
        
        // Start session timeout timer
        startSessionTimer()
        
        debugLog("Session tracking initialized", data: ["sessionId": sessionId])
    }
    
    /// Start session timeout timer
    private func startSessionTimer() {
        sessionTimer?.invalidate()
        
        sessionTimer = Timer.scheduledTimer(withTimeInterval: config.sessionTimeoutMs / 1000, repeats: false) { [weak self] _ in
            self?.handleSessionTimeout()
        }
    }
    
    /// Handle session timeout
    private func handleSessionTimeout() {
        guard let session = currentSession else { return }
        
        let sessionDuration = Date().timeIntervalSince(session.startTime)
        
        // Track session end
        trackingDelegate?.trackEvent("session_end", properties: [
            "session_id": session.sessionId,
            "session_duration": sessionDuration,
            "event_count": session.eventCount,
            "pageview": session.pageviewCount,
            "app_version": session.appVersion,
            "os_version": session.osVersion
        ])
        
        currentSession = nil
        debugLog("Session ended due to timeout", data: ["duration": sessionDuration])
    }
    
    /// Update session activity
    private func updateSessionActivity() {
        lastActivityTime = Date()
        
        if let session = currentSession {
            var updatedSession = session
            updatedSession.lastActivityTime = lastActivityTime
            updatedSession.eventCount += 1
            currentSession = updatedSession
        }
        
        // Reset session timer
        if config.trackSessions {
            startSessionTimer()
        }
    }
    
    // MARK: - Screen Tracking

    /// Update session counters and screen duration tracking for a screen view.
    /// The actual `pageview` event is fired by the SDK's `screen()` method —
    /// this only updates internal state to avoid double-firing.
    func recordScreenView(_ screenName: String) {
        guard config.trackScreenViews else { return }

        // Start new screen tracking
        self.currentScreen = screenName
        self.screenStartTime = Date()

        // Update session pageview count
        if var session = currentSession {
            session.pageviewCount += 1
            currentSession = session
        }

        updateSessionActivity()

        debugLog("Screen view recorded", data: ["screen": screenName])
    }

    /// Get session data to enrich a pageview event.
    /// Called AFTER `recordScreenView()` so pageview count is already incremented.
    func getScreenViewEnrichment() -> EventData? {
        guard let session = currentSession else { return nil }

        var enrichment: EventData = [
            "session_id": session.sessionId,
            "pageviews_in_session": session.pageviewCount
        ]

        if let previousScreen = currentScreen {
            enrichment["previous_screen"] = previousScreen
        }

        return enrichment
    }
    
    // MARK: - App Lifecycle Tracking
    
    /// Set up app lifecycle observers
    private func setupAppLifecycleObservers() {
        #if canImport(UIKit)
        // App did become active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // App will resign active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        // App did enter background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        // App will enter foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // App will terminate
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }
    
    #if canImport(UIKit)
    @objc private func appDidBecomeActive() {
        // Resume session if needed
        if config.trackSessions && currentSession == nil && isInitialized {
            Task {
                await initializeSessionTracking()
            }
        }

        updateSessionActivity()
        debugLog("App became active")
    }

    @objc private func appWillResignActive() {
        debugLog("App will resign active")
    }

    @objc private func appDidEnterBackground() {
        debugLog("App entered background")
    }

    @objc private func appWillEnterForeground() {
        debugLog("App will enter foreground")
    }

    @objc private func appWillTerminate() {
        // End session on app terminate
        if let session = currentSession {
            let sessionDuration = Date().timeIntervalSince(session.startTime)

            trackingDelegate?.trackEvent("session_end", properties: [
                "session_id": session.sessionId,
                "session_duration": sessionDuration,
                "event_count": session.eventCount,
                "pageview": session.pageviewCount,
                "reason": "app_terminated"
            ])
        }

        debugLog("App will terminate")
    }
    #endif
    
    // MARK: - App Update Tracking
    
    // MARK: - Cleanup
    
    /// Clean up resources
    func destroy() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        
        NotificationCenter.default.removeObserver(self)
        
        // End current session
        if let session = currentSession {
            let sessionDuration = Date().timeIntervalSince(session.startTime)
            
            trackingDelegate?.trackEvent("session_end", properties: [
                "session_id": session.sessionId,
                "session_duration": sessionDuration,
                "event_count": session.eventCount,
                "reason": "sdk_destroyed"
            ])
        }
        
        debugLog("Auto events manager destroyed")
    }
    
    deinit {
        destroy()
    }
} 