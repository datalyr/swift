//
//  ContentView.swift
//  DatalyrTestApp
//
//  Created by czy on 6/23/25.
//

import SwiftUI
import DatalyrSDK

struct ContentView: View {
    @State private var isLoggedIn = false
    @State private var username = ""
    @State private var eventCount = 0
    @State private var showingStatus = false
    @State private var logs: [String] = []
    @State private var sdkInitialized = false
    @State private var lastButtonPressed = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack {
                        Text("🧪 Datalyr iOS SDK")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Debug & Test App")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        
                        Text("Events sent: \(eventCount)")
                            .font(.headline)
                            .padding(.top, 5)
                        
                        if !lastButtonPressed.isEmpty {
                            Text("Last: \(lastButtonPressed)")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding()
                    
                    // SDK Status
                    GroupBox("📊 SDK Status") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Initialized:")
                                Spacer()
                                Text(sdkInitialized ? "✅ Yes" : "❌ No")
                                    .foregroundColor(sdkInitialized ? .green : .red)
                            }
                            
                            if sdkInitialized {
                                let status = DatalyrSDK.shared.getStatus()
                                
                                HStack {
                                    Text("Workspace:")
                                    Spacer()
                                    Text(status.workspaceId.isEmpty ? "Not set" : status.workspaceId)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                HStack {
                                    Text("Visitor ID:")
                                    Spacer()
                                    Text(String(status.visitorId.prefix(8)) + "...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                HStack {
                                    Text("Queue Size:")
                                    Spacer()
                                    Text("\(status.queueStats.queueSize)")
                                        .foregroundColor(status.queueStats.queueSize > 0 ? .orange : .green)
                                }
                                
                                if let userId = status.currentUserId {
                                    HStack {
                                        Text("User ID:")
                                        Spacer()
                                        Text(userId)
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    
                    // Initialize SDK Button
                    if !sdkInitialized {
                        Button("🚀 Initialize SDK") {
                            initializeSDK()
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.headline)
                    } else {
                        // Quick Actions when SDK is ready
                        HStack(spacing: 15) {
                            Button("📊 Check Status") {
                                lastButtonPressed = "Check Status"
                                checkSDKStatus()
                            }
                            .buttonStyle(.borderedProminent)
                            .font(.headline)
                            
                            Button("🌐 Test Network") {
                                lastButtonPressed = "Test Network"
                                debugNetwork()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    // User Management
                    if sdkInitialized {
                        GroupBox("👤 User Management") {
                            VStack(spacing: 15) {
                                if isLoggedIn {
                                    VStack(spacing: 10) {
                                        Text("Logged in as: \(username)")
                                            .font(.headline)
                                            .foregroundColor(.green)
                                        
                                        HStack(spacing: 15) {
                                            Button("Update Profile") {
                                                updateProfile()
                                            }
                                            .buttonStyle(.bordered)
                                            
                                            Button("Logout") {
                                                logout()
                                            }
                                            .buttonStyle(.borderedProminent)
                                        }
                                    }
                                } else {
                                    VStack(spacing: 10) {
                                        TextField("Enter username", text: $username)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                        
                                        Button("Login") {
                                            login()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(username.isEmpty)
                                    }
                                }
                            }
                            .padding()
                        }
                        
                        // Event Testing
                        GroupBox("📈 Event Testing") {
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 12) {
                                
                                Button("📤 Simple Event") {
                                    lastButtonPressed = "Simple Event"
                                    addLog("🔘 Simple Event button tapped!")
                                    trackEvent("simple_event")
                                }
                                .buttonStyle(.bordered)
                                
                                Button("📤 Page View") {
                                    lastButtonPressed = "Page View"
                                    addLog("🔘 Page View button tapped!")
                                    trackPageView()
                                }
                                .buttonStyle(.bordered)
                                
                                Button("📤 Purchase") {
                                    lastButtonPressed = "Purchase"
                                    trackEvent("purchase", properties: [
                                        "product_id": "test_123",
                                        "amount": 29.99,
                                        "currency": "USD"
                                    ])
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Button Click") {
                                    trackEvent("button_click", properties: [
                                        "button_name": "test_button",
                                        "screen": "debug_view"
                                    ])
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Error Event") {
                                    trackEvent("error", properties: [
                                        "error_type": "test_error",
                                        "message": "This is a test error"
                                    ])
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Custom Event") {
                                    trackEvent("custom_test", properties: [
                                        "test_data": "custom_value",
                                        "timestamp": Date().timeIntervalSince1970
                                    ])
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding()
                        }
                        
                        // SDK Actions
                        GroupBox("🔧 SDK Actions") {
                            VStack(spacing: 12) {
                                HStack(spacing: 15) {
                                    Button("Flush Queue") {
                                        flushQueue()
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button("Reset User") {
                                        resetUser()
                                    }
                                    .buttonStyle(.bordered)
                                }
                                
                                Button("Test Attribution") {
                                    testAttribution()
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Test Connection") {
                                    lastButtonPressed = "Test Connection"
                                    testConnection()
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Debug Network") {
                                    lastButtonPressed = "Debug Network"
                                    debugNetwork()
                                }
                                .buttonStyle(.bordered)
                                
                                Button("🔥 Direct Send") {
                                    lastButtonPressed = "Direct Send"
                                    sendDirectToSupabase()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding()
                        }
                    }
                    
                    // Activity Log
                    GroupBox("📋 Activity Log") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                if logs.isEmpty {
                                    Text("No activity yet...")
                                        .foregroundColor(.secondary)
                                        .italic()
                                } else {
                                    ForEach(logs.indices, id: \.self) { index in
                                        Text(logs[index])
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                        .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Datalyr Test")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - SDK Functions
    
    private func initializeSDK() {
        addLog("🚀 Starting SDK initialization...")
        
        Task { @MainActor in
            do {
                let config = DatalyrConfig(
                    workspaceId: "YOUR_WORKSPACE_ID",
                    apiKey: "YOUR_API_KEY",
                    debug: true // Enable debug logging
                )
                
                addLog("⚙️ Config created - workspace: \(config.workspaceId)")
                
                try await DatalyrSDK.shared.initialize(config: config)
                
                sdkInitialized = true
                addLog("✅ SDK initialized successfully")
                
                // Log the SDK status
                let status = DatalyrSDK.shared.getStatus()
                addLog("📊 Visitor ID: \(String(status.visitorId.prefix(8)))...")
                addLog("📊 Session ID: \(String(status.sessionId.prefix(8)))...")
            } catch {
                addLog("❌ SDK initialization failed: \(error)")
                print("SDK Error Details: \(error)")
            }
        }
    }
    
    private func trackEvent(_ eventName: String, properties: [String: Any]? = nil) {
        // Immediate UI feedback
        lastButtonPressed = eventName
        eventCount += 1
        addLog("🎯 Tracking: \(eventName)")
        
        // Check if SDK is initialized
        if !sdkInitialized {
            addLog("⚠️ SDK not initialized! Please initialize first.")
            return
        }
        
        // Fire and forget - don't wait for completion
        Task.detached {
            do {
                // Track the event
                await DatalyrSDK.shared.track(eventName, eventData: properties)
                
                await MainActor.run {
                    self.addLog("✅ Event tracked: \(eventName)")
                }
                
                // Try to flush in background (don't wait)
                Task.detached {
                    await DatalyrSDK.shared.flush()
                    await MainActor.run {
                        let status = DatalyrSDK.shared.getStatus()
                        self.addLog("📊 Queue size: \(status.queueStats.queueSize)")
                    }
                }
                
            } catch {
                await MainActor.run {
                    self.addLog("❌ Failed to track \(eventName): \(error)")
                }
            }
        }
    }
    
    private func trackPageView() {
        addLog("📱 Tracking and sending page view...")
        
        Task {
            do {
                await DatalyrSDK.shared.screen("test_screen", properties: [
                    "screen_name": "debug_screen",
                    "timestamp": Date().timeIntervalSince1970
                ])
                
                // Immediately send it
                await DatalyrSDK.shared.flush()
                
                await MainActor.run {
                    eventCount += 1
                    addLog("✅ Page view sent successfully")
                    
                    // Show queue status
                    let status = DatalyrSDK.shared.getStatus()
                    addLog("📊 Queue size: \(status.queueStats.queueSize)")
                }
            } catch {
                await MainActor.run {
                    addLog("❌ Failed to send page view: \(error)")
                    print("Screen Error: \(error)")
                }
            }
        }
    }
    
    private func login() {
        Task {
            await DatalyrSDK.shared.identify(username, properties: [
                "email": "\(username)@test.com",
                "signup_date": Date().timeIntervalSince1970
            ])
            await MainActor.run {
                isLoggedIn = true
                addLog("👤 User identified: \(username)")
            }
        }
    }
    
    private func logout() {
        Task {
            await DatalyrSDK.shared.reset()
            await MainActor.run {
                isLoggedIn = false
                username = ""
                addLog("👋 User logged out")
            }
        }
    }
    
    private func updateProfile() {
        Task {
            await DatalyrSDK.shared.identify(username, properties: [
                "last_update": Date().timeIntervalSince1970,
                "profile_version": "2.0"
            ])
            await MainActor.run {
                addLog("📝 Profile updated")
            }
        }
    }
    
    private func flushQueue() {
        addLog("🚀 Attempting to flush queue...")
        
        Task { @MainActor in
            do {
                await DatalyrSDK.shared.flush()
                addLog("✅ Queue flushed successfully")
                
                // Show updated queue status
                let status = DatalyrSDK.shared.getStatus()
                addLog("📊 Queue size after flush: \(status.queueStats.queueSize)")
            } catch {
                addLog("❌ Failed to flush queue: \(error)")
                print("Flush Error: \(error)")
            }
        }
    }
    
    private func resetUser() {
        Task {
            await DatalyrSDK.shared.reset()
            await MainActor.run {
                isLoggedIn = false
                username = ""
                addLog("🔄 User session reset")
            }
        }
    }
    
    private func testAttribution() {
        Task {
            let attribution = DatalyrSDK.shared.getAttributionData()
            await MainActor.run {
                addLog("📊 Attribution data retrieved")
                addLog("   Install time: \(attribution.installTime ?? "none")")
            }
        }
    }
    
    private func testConnection() {
        addLog("🌐 Testing SDK connection...")
        
        if !sdkInitialized {
            addLog("⚠️ SDK not initialized!")
            return
        }
        
        Task {
            do {
                // Send a simple test event
                await DatalyrSDK.shared.track("connection_test", eventData: [
                    "test": true,
                    "timestamp": Date().timeIntervalSince1970
                ])
                
                // Force flush to see if network works
                await DatalyrSDK.shared.flush()
                
                await MainActor.run {
                    addLog("✅ Connection test completed")
                    let status = DatalyrSDK.shared.getStatus()
                    addLog("📊 Queue size: \(status.queueStats.queueSize)")
                }
            } catch {
                await MainActor.run {
                    addLog("❌ Connection test failed: \(error)")
                }
            }
        }
    }
    
    private func checkSDKStatus() {
        addLog("📊 Checking SDK status...")
        
        if !sdkInitialized {
            addLog("⚠️ SDK not initialized!")
            return
        }
        
        let status = DatalyrSDK.shared.getStatus()
        addLog("✅ SDK Status:")
        addLog("   Workspace: \(status.workspaceId)")
        addLog("   Visitor: \(String(status.visitorId.prefix(8)))...")
        addLog("   Session: \(String(status.sessionId.prefix(8)))...")
        addLog("   Queue size: \(status.queueStats.queueSize)")
        addLog("   Processing: \(status.queueStats.isProcessing)")
        addLog("   Online: \(status.queueStats.isOnline)")
        
                 if let userId = status.currentUserId {
             addLog("   User: \(userId)")
         }
     }
     
         private func debugNetwork() {
        addLog("🌐 Testing network connectivity...")
        
        Task { @MainActor in
            do {
                // Test basic network connectivity
                let url = URL(string: "https://httpbin.org/status/200")!
                let (_, response) = try await URLSession.shared.data(from: url)
                
                if let httpResponse = response as? HTTPURLResponse {
                    addLog("✅ Basic network OK: \(httpResponse.statusCode)")
                }
                
                // Test Datalyr endpoint
                let datalyrUrl = URL(string: "https://datalyr-ingest.datalyr-ingest.workers.dev")!
                let (_, datalyrResponse) = try await URLSession.shared.data(from: datalyrUrl)
                
                if let httpResponse = datalyrResponse as? HTTPURLResponse {
                    addLog("✅ Datalyr endpoint OK: \(httpResponse.statusCode)")
                    
                    // Now try sending a test event manually
                    sendTestEvent()
                }
                
            } catch {
                addLog("❌ Network test failed: \(error)")
            }
        }
    }
     
         private func sendTestEvent() {
        addLog("📤 Sending manual test event...")
        
        Task { @MainActor in
            do {
                // Send event and immediately flush
                await DatalyrSDK.shared.track("manual_test", eventData: [
                    "test_type": "manual_debug",
                    "timestamp": Date().timeIntervalSince1970
                ])
                
                addLog("📦 Event queued, flushing immediately...")
                await DatalyrSDK.shared.flush()
                
                // Wait a moment and check status
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                
                let status = DatalyrSDK.shared.getStatus()
                addLog("📊 After flush - Queue size: \(status.queueStats.queueSize)")
                
                if status.queueStats.queueSize == 0 {
                    addLog("✅ Events sent successfully!")
                } else {
                    addLog("⚠️ Events still in queue - check network/auth")
                }
            } catch {
                addLog("❌ Manual test failed: \(error)")
            }
                 }
     }
     
     private func sendDirectToSupabase() {
         addLog("🔥 Sending directly to Supabase...")
         
         Task {
             do {
                 // Create the exact payload structure Datalyr expects
                 let payload = [
                     "workspaceId": "YOUR_WORKSPACE_ID",
                     "visitorId": UUID().uuidString, // Use proper UUID format
                     "sessionId": UUID().uuidString,  // Use proper UUID format
                     "eventId": UUID().uuidString,
                     "eventName": "direct_test",
                     "eventData": [
                         "test": true,
                         "source": "ios_direct",
                         "timestamp": Date().timeIntervalSince1970
                     ],
                     "source": "mobile_app", // Use correct enum value
                     "timestamp": ISO8601DateFormatter().string(from: Date())
                 ] as [String: Any]
                 
                 // Convert to JSON
                 let jsonData = try JSONSerialization.data(withJSONObject: payload)
                 
                 // Create request
                 var request = URLRequest(url: URL(string: "https://datalyr-ingest.datalyr-ingest.workers.dev")!)
                 request.httpMethod = "POST"
                 request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                 request.setValue("Bearer YOUR_API_KEY", forHTTPHeaderField: "Authorization")
                 request.setValue("YOUR_API_KEY", forHTTPHeaderField: "X-API-Key")
                 request.httpBody = jsonData
                 
                 await MainActor.run {
                     addLog("📤 Sending request to: \(request.url?.absoluteString ?? "unknown")")
                     addLog("📤 Headers: Authorization: Bearer [API_KEY], Content-Type: application/json")
                     addLog("📤 Payload: \(String(data: jsonData, encoding: .utf8) ?? "invalid")")
                 }
                 
                 // Print to Xcode console as well
                 print("🔥 DIRECT SEND REQUEST:")
                 print("URL: \(request.url?.absoluteString ?? "unknown")")
                 print("Method: \(request.httpMethod ?? "unknown")")
                 print("Headers: \(request.allHTTPHeaderFields ?? [:])")
                 print("Payload: \(String(data: jsonData, encoding: .utf8) ?? "invalid")")
                 
                 // Send request
                 let (data, response) = try await URLSession.shared.data(for: request)
                 
                 if let httpResponse = response as? HTTPURLResponse {
                     let responseString = String(data: data, encoding: .utf8) ?? "No response data"
                     
                     await MainActor.run {
                         if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                             addLog("✅ SUCCESS! Status: \(httpResponse.statusCode)")
                             addLog("📥 Response: \(responseString)")
                             
                             // Print to Xcode console
                             print("🔥 DIRECT SEND SUCCESS:")
                             print("Status: \(httpResponse.statusCode)")
                             print("Response: \(responseString)")
                         } else {
                             addLog("❌ FAILED! Status: \(httpResponse.statusCode)")
                             addLog("📥 Error: \(responseString)")
                             addLog("📥 All Headers: \(httpResponse.allHeaderFields)")
                             
                             // Print to Xcode console
                             print("🔥 DIRECT SEND FAILED:")
                             print("Status: \(httpResponse.statusCode)")
                             print("Response: \(responseString)")
                             print("Headers: \(httpResponse.allHeaderFields)")
                         }
                     }
                 }
                 
                              } catch {
                     await MainActor.run {
                         addLog("❌ Direct send failed: \(error)")
                         addLog("❌ Error details: \(error.localizedDescription)")
                         
                         // Print to Xcode console as well
                         print("🔥 DIRECT SEND ERROR:")
                         print("Error: \(error)")
                         print("Localized: \(error.localizedDescription)")
                         
                         if let urlError = error as? URLError {
                             print("URL Error Code: \(urlError.code.rawValue)")
                             print("URL Error Description: \(urlError.localizedDescription)")
                             addLog("❌ URL Error: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                         }
                     }
                 }
         }
     }
     
     private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.insert("[\(timestamp)] \(message)", at: 0)
        
        // Keep only last 50 logs
        if logs.count > 50 {
            logs = Array(logs.prefix(50))
        }
    }
}

#Preview {
    ContentView()
}
