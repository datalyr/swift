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
                                
                                Button("Simple Event") {
                                    trackEvent("simple_event")
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Page View") {
                                    trackPageView()
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Purchase") {
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
        Task {
            do {
                let config = DatalyrConfig(
                    workspaceId: "BFXm1IpyVe",
                    apiKey: "dk_KCrEZT9saU4ZlTwr2HHnuaia3jKDHcuf"
                )
                
                try await DatalyrSDK.shared.initialize(config)
                
                await MainActor.run {
                    sdkInitialized = true
                    addLog("✅ SDK initialized successfully")
                }
            } catch {
                await MainActor.run {
                    addLog("❌ SDK initialization failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func trackEvent(_ eventName: String, properties: [String: Any]? = nil) {
        Task {
            await DatalyrSDK.shared.track(eventName, eventData: properties)
            await MainActor.run {
                eventCount += 1
                addLog("📊 Tracked: \(eventName)")
            }
        }
    }
    
    private func trackPageView() {
        Task {
            await DatalyrSDK.shared.screen("test_screen", properties: [
                "screen_name": "debug_screen",
                "timestamp": Date().timeIntervalSince1970
            ])
            await MainActor.run {
                eventCount += 1
                addLog("📱 Page view tracked")
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
        Task {
            await DatalyrSDK.shared.flush()
            await MainActor.run {
                addLog("🚀 Queue flushed")
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
