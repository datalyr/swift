import SwiftUI
import DatalyrSDK

@main
struct DatalyrTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await initializeDatalyr()
                }
        }
    }
    
    private func initializeDatalyr() async {
        do {
            try await DatalyrSDK.configure(
                workspaceId: "your_workspace_id", // 👈 Change this!
                apiKey: "dk_your_api_key",        // 👈 Change this!
                debug: true,
                enableAutoEvents: true,
                enableAttribution: true
            )
            
            // Enable automatic screen tracking for UIKit components
            DatalyrSDK.enableAutomaticScreenTracking()
            
            print("✅ Datalyr SDK initialized successfully")
        } catch {
            print("❌ Failed to initialize Datalyr SDK: \(error)")
        }
    }
}

struct ContentView: View {
    @State private var isLoggedIn = false
    @State private var username = ""
    @State private var eventCount = 0
    @State private var showingStatus = false
    @State private var logs: [String] = []
    
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
                            let status = DatalyrSDK.shared.getStatus()
                            
                            HStack {
                                Text("Initialized:")
                                Spacer()
                                Text(status.initialized ? "✅ Yes" : "❌ No")
                                    .foregroundColor(status.initialized ? .green : .red)
                            }
                            
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
                        .padding()
                    }
                    
                    // User Management
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
                                trackEvent("page_view", properties: [
                                    "page": "test_page",
                                    "referrer": "app"
                                ])
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
                    
                    // Attribution Testing
                    GroupBox("🔗 Attribution Testing") {
                        VStack(spacing: 15) {
                            Text("Test deep link attribution")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 12) {
                                
                                Button("UTM Test") {
                                    simulateDeepLink("utm_source=facebook&utm_campaign=test")
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Facebook Click") {
                                    simulateDeepLink("fbclid=IwAR123456789")
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Google Click") {
                                    simulateDeepLink("gclid=TeSter-123_456")
                                }
                                .buttonStyle(.bordered)
                                
                                Button("LYR Tag") {
                                    simulateDeepLink("lyr=test_campaign&dl_tag=summer_sale")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding()
                    }
                    
                    // SDK Actions
                    GroupBox("⚙️ SDK Actions") {
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            
                            Button("Flush Queue") {
                                flushEvents()
                            }
                            .buttonStyle(.bordered)
                            
                            Button("Reset User") {
                                resetUser()
                            }
                            .buttonStyle(.bordered)
                            
                            Button("Get Attribution") {
                                showAttribution()
                            }
                            .buttonStyle(.bordered)
                            
                            Button("Test Offline") {
                                testOfflineMode()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                    }
                    
                    // Recent Logs
                    GroupBox("📝 Recent Logs") {
                        VStack(alignment: .leading, spacing: 5) {
                            if logs.isEmpty {
                                Text("No logs yet...")
                                    .foregroundColor(.secondary)
                                    .italic()
                            } else {
                                ForEach(logs.suffix(5).reversed(), id: \.self) { log in
                                    Text(log)
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    
                    // Instructions
                    GroupBox("📖 Setup Instructions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. Update your workspaceId and apiKey above")
                            Text("2. Check Xcode console for detailed logs")
                            Text("3. Test events and check your Datalyr dashboard")
                            Text("4. Events appear with source: 'ios_app'")
                            Text("5. Attribution data is automatically captured")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Datalyr Test")
            .refreshable {
                // Refresh status
            }
        }
        .datalyrScreen("Debug Test View", properties: [
            "is_logged_in": isLoggedIn,
            "event_count": eventCount
        ])
    }
    
    // MARK: - Actions
    
    private func login() {
        Task {
            await datalyrIdentify(username, properties: [
                "email": "\(username)@example.com",
                "plan": "test_user",
                "signup_date": Date().timeIntervalSince1970
            ])
            
            await datalyrTrack("user_login", properties: [
                "username": username,
                "login_method": "test_app"
            ])
            
            isLoggedIn = true
            addLog("✅ User logged in: \(username)")
            eventCount += 1
        }
    }
    
    private func logout() {
        Task {
            await datalyrTrack("user_logout", properties: [
                "username": username
            ])
            
            await datalyrReset()
            
            isLoggedIn = false
            username = ""
            addLog("✅ User logged out and reset")
            eventCount += 1
        }
    }
    
    private func updateProfile() {
        Task {
            await datalyrIdentify(username, properties: [
                "email": "\(username)@example.com",
                "plan": "premium_user",
                "last_updated": Date().timeIntervalSince1970
            ])
            
            addLog("✅ Profile updated for \(username)")
        }
    }
    
    private func trackEvent(_ eventName: String, properties: [String: Any]? = nil) {
        Task {
            await datalyrTrack(eventName, properties: properties)
            eventCount += 1
            
            let propertiesStr = properties?.isEmpty == false ? " with \(properties!.count) properties" : ""
            addLog("📊 Tracked: \(eventName)\(propertiesStr)")
        }
    }
    
    private func simulateDeepLink(_ parameters: String) {
        Task {
            // Simulate deep link handling
            if let url = URL(string: "datalyr-test://test?\(parameters)") {
                await DatalyrSDK.shared.handleDeepLink(url)
                addLog("🔗 Simulated deep link: \(parameters)")
            }
        }
    }
    
    private func flushEvents() {
        Task {
            await datalyrFlush()
            addLog("🚀 Events flushed to server")
        }
    }
    
    private func resetUser() {
        Task {
            await datalyrReset()
            isLoggedIn = false
            username = ""
            addLog("🔄 User session reset")
        }
    }
    
    private func showAttribution() {
        let attribution = DatalyrSDK.shared.getAttributionData()
        
        if let utmSource = attribution.utmSource {
            addLog("🎯 Attribution: source=\(utmSource)")
        } else if let fbclid = attribution.fbclid {
            addLog("🎯 Attribution: fbclid=\(fbclid)")
        } else if let gclid = attribution.gclid {
            addLog("🎯 Attribution: gclid=\(gclid)")
        } else if let lyr = attribution.lyr {
            addLog("🎯 Attribution: lyr=\(lyr)")
        } else {
            addLog("🎯 No attribution data found")
        }
    }
    
    private func testOfflineMode() {
        Task {
            await datalyrTrack("offline_test", properties: [
                "test_mode": "offline_simulation",
                "timestamp": Date().timeIntervalSince1970
            ])
            eventCount += 1
            addLog("📴 Offline event queued")
        }
    }
    
    private func addLog(_ message: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.logTime.string(from: Date())
            logs.append("[\(timestamp)] \(message)")
            
            // Keep only last 20 logs
            if logs.count > 20 {
                logs.removeFirst()
            }
        }
        
        // Also print to console
        print(message)
    }
}

// MARK: - Date Formatter Extension

extension DateFormatter {
    static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
} 