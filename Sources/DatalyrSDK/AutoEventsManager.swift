import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Auto Events Tracking Delegate

/// Protocol for auto events to communicate with the main SDK
internal protocol AutoEventsTrackingDelegate: AnyObject {
    func trackEvent(_ eventName: String, properties: EventData?)
    func trackScreenView(_ screenName: String, properties: EventData?)
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
        
        // Set up app lifecycle observers
        setupAppLifecycleObservers()
        
        // Initialize session tracking
        if config.trackSessions {
            await initializeSessionTracking()
        }
        
        // Check for app updates
        if config.trackAppUpdates {
            await checkAndTrackAppUpdate()
        }
        
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
    
    /// Track screen view
    func trackScreenView(_ screenName: String, properties: EventData? = nil) {
        guard config.trackScreenViews else { return }
        
        // End previous screen tracking
        if let currentScreen = currentScreen, let screenStartTime = screenStartTime {
            let viewDuration = Date().timeIntervalSince(screenStartTime)
            
            trackingDelegate?.trackEvent("screen_end", properties: [
                "screen": currentScreen,
                "view_duration": viewDuration
            ])
        }
        
        // Start new screen tracking
        self.currentScreen = screenName
        self.screenStartTime = Date()
        
        var screenProperties: EventData = [
            "screen": screenName,
            "platform": "ios",
            "app_version": getAppVersion()
        ]
        
        if let properties = properties {
            screenProperties.merge(properties) { (_, new) in new }
        }
        
        trackingDelegate?.trackScreenView(screenName, properties: screenProperties)
        
        // Update session pageview count
        if var session = currentSession {
            session.pageviewCount += 1
            currentSession = session
        }
        
        updateSessionActivity()
        
        debugLog("Screen view tracked", data: ["screen": screenName])
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
        trackingDelegate?.trackEvent("app_became_active", properties: [
            "platform": "ios",
            "app_version": getAppVersion()
        ])
        
        // Resume session if needed
        if config.trackSessions && currentSession == nil {
            Task {
                await initializeSessionTracking()
            }
        }
        
        updateSessionActivity()
        debugLog("App became active")
    }
    
    @objc private func appWillResignActive() {
        trackingDelegate?.trackEvent("app_will_resign_active", properties: [
            "platform": "ios",
            "app_version": getAppVersion()
        ])
        
        debugLog("App will resign active")
    }
    
    @objc private func appDidEnterBackground() {
        trackingDelegate?.trackEvent("app_backgrounded", properties: [
            "platform": "ios",
            "app_version": getAppVersion()
        ])
        
        // End current screen tracking
        if let currentScreen = currentScreen, let screenStartTime = screenStartTime {
            let viewDuration = Date().timeIntervalSince(screenStartTime)
            
            trackingDelegate?.trackEvent("screen_end", properties: [
                "screen": currentScreen,
                "view_duration": viewDuration,
                "reason": "app_backgrounded"
            ])
        }
        
        debugLog("App entered background")
    }
    
    @objc private func appWillEnterForeground() {
        trackingDelegate?.trackEvent("app_foregrounded", properties: [
            "platform": "ios",
            "app_version": getAppVersion()
        ])
        
        debugLog("App will enter foreground")
    }
    
    @objc private func appWillTerminate() {
        // End session
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
        
        trackingDelegate?.trackEvent("app_terminated", properties: [
            "platform": "ios",
            "app_version": getAppVersion()
        ])
        
        debugLog("App will terminate")
    }
    #endif
    
    // MARK: - App Update Tracking
    
    /// Check and track app updates
    private func checkAndTrackAppUpdate() async {
        let currentVersion = getAppVersion()
        
        if let lastVersion = lastTrackedVersion {
            if lastVersion != currentVersion {
                // App was updated
                trackingDelegate?.trackEvent("app_update", properties: [
                    "previous_version": lastVersion,
                    "current_version": currentVersion,
                    "platform": "ios"
                ])
                
                debugLog("App update tracked", data: [
                    "from": lastVersion,
                    "to": currentVersion
                ])
            }
        }
        
        // Save current version
        await storage.setString(StorageKeys.lastAppVersion, value: currentVersion)
        lastTrackedVersion = currentVersion
    }
    
    // MARK: - Performance Tracking
    
    /// Track app launch performance
    func trackAppLaunchPerformance() {
        guard config.trackPerformance else { return }
        
        // This would typically measure time from app launch to this point
        // For now, we'll track a simple app launch event
        trackingDelegate?.trackEvent("app_launch_performance", properties: [
            "platform": "ios",
            "app_version": getAppVersion(),
            "launch_time": Date().timeIntervalSince1970
        ])
        
        debugLog("App launch performance tracked")
    }
    
    /// Track memory usage
    func trackMemoryUsage() {
        guard config.trackPerformance else { return }
        
        let memoryUsage = getMemoryUsage()
        
        trackingDelegate?.trackEvent("memory_usage", properties: [
            "used_memory_mb": memoryUsage.used,
            "available_memory_mb": memoryUsage.available,
            "platform": "ios"
        ])
        
        debugLog("Memory usage tracked", data: memoryUsage)
    }
    
    /// Get current memory usage
    private func getMemoryUsage() -> (used: Double, available: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / 1024.0 / 1024.0
            return (used: usedMB, available: 0) // Available memory is harder to get on iOS
        } else {
            return (used: 0, available: 0)
        }
    }
    
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