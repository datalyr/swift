import SwiftUI
import DatalyrSDK

// MARK: - App Entry Point

@main
struct DatalyrExampleApp: App {
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
                workspaceId: "your_workspace_id",
                apiKey: "your_api_key",
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

// MARK: - Main Content View

struct ContentView: View {
    @State private var isLoggedIn = false
    @State private var username = ""
    @State private var showingProfile = false
    
    var body: some View {
        NavigationView {
            if isLoggedIn {
                HomeView(username: username) {
                    logout()
                }
            } else {
                LoginView { username in
                    login(username: username)
                }
            }
        }
    }
    
    private func login(username: String) {
        Task {
            // Track login event
            await datalyrTrack("user_login", properties: [
                "username": username,
                "login_method": "manual"
            ])
            
            // Identify the user
            await datalyrIdentify(username, properties: [
                "username": username,
                "login_time": Date().timeIntervalSince1970
            ])
            
            self.username = username
            self.isLoggedIn = true
        }
    }
    
    private func logout() {
        Task {
            // Track logout event
            await datalyrTrack("user_logout", properties: [
                "username": username,
                "session_duration": 300 // Example duration
            ])
            
            // Reset user session
            await datalyrReset()
            
            self.isLoggedIn = false
            self.username = ""
        }
    }
}

// MARK: - Login View

struct LoginView: View {
    @State private var username = ""
    let onLogin: (String) -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to Datalyr Demo")
                .font(.title)
                .fontWeight(.bold)
            
            TextField("Enter username", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
            
            Button("Login") {
                if !username.isEmpty {
                    onLogin(username)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(username.isEmpty)
            
            Button("Track Demo Event") {
                Task {
                    await datalyrTrack("demo_button_clicked", properties: [
                        "screen": "login",
                        "button_type": "demo"
                    ])
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .datalyrScreen("Login Screen", properties: [
            "screen_type": "authentication"
        ])
    }
}

// MARK: - Home View

struct HomeView: View {
    let username: String
    let onLogout: () -> Void
    
    @State private var products = [
        Product(id: "1", name: "iPhone 15", price: 999.99),
        Product(id: "2", name: "MacBook Pro", price: 1999.99),
        Product(id: "3", name: "AirPods Pro", price: 249.99)
    ]
    
    var body: some View {
        VStack {
            Text("Welcome, \(username)!")
                .font(.title2)
                .padding()
            
            NavigationLink("View Profile") {
                ProfileView(username: username)
            }
            .buttonStyle(.bordered)
            .padding()
            
            List(products) { product in
                ProductRow(product: product)
            }
            
            Button("Logout") {
                onLogout()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .navigationTitle("Home")
        .datalyrScreen("Home Screen", properties: [
            "username": username,
            "product_count": products.count
        ])
        .onAppear {
            Task {
                await datalyrTrack("home_screen_viewed", properties: [
                    "username": username,
                    "product_count": products.count
                ])
            }
        }
    }
}

// MARK: - Profile View

struct ProfileView: View {
    let username: String
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 100))
                .foregroundColor(.blue)
            
            Text(username)
                .font(.title)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Account Details:")
                    .font(.headline)
                
                Text("Username: \(username)")
                Text("Member since: Today")
                Text("Plan: Free")
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            
            Button("Update Profile") {
                Task {
                    await datalyrTrack("profile_update_clicked", properties: [
                        "username": username,
                        "section": "profile_details"
                    ])
                    
                    // Simulate profile update
                    await datalyrIdentify(username, properties: [
                        "username": username,
                        "plan": "premium",
                        "last_updated": Date().timeIntervalSince1970
                    ])
                }
            }
            .buttonStyle(.borderedProminent)
            
            Spacer()
        }
        .padding()
        .navigationTitle("Profile")
        .datalyrScreen("Profile Screen", properties: [
            "username": username
        ])
    }
}

// MARK: - Product Row

struct ProductRow: View {
    let product: Product
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(product.name)
                    .font(.headline)
                Text("$\(product.price, specifier: "%.2f")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Buy") {
                Task {
                    await datalyrTrack("purchase_initiated", properties: [
                        "product_id": product.id,
                        "product_name": product.name,
                        "price": product.price,
                        "currency": "USD"
                    ])
                    
                    // Simulate purchase
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    
                    await datalyrTrack("purchase_completed", properties: [
                        "product_id": product.id,
                        "product_name": product.name,
                        "price": product.price,
                        "currency": "USD",
                        "payment_method": "card"
                    ])
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Models

struct Product: Identifiable {
    let id: String
    let name: String
    let price: Double
}

// MARK: - UIKit Example

import UIKit

class ExampleViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "UIKit Example"
        view.backgroundColor = .systemBackground
        
        setupUI()
        
        // This will automatically track screen view if automatic tracking is enabled
        // Or manually track:
        Task {
            await datalyrScreen("UIKit Example", properties: [
                "controller": "ExampleViewController"
            ])
        }
    }
    
    private func setupUI() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        let titleLabel = UILabel()
        titleLabel.text = "UIKit Integration Example"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textAlignment = .center
        
        let eventButton = UIButton(type: .system)
        eventButton.setTitle("Track Event", for: .normal)
        eventButton.addTarget(self, action: #selector(trackEventTapped), for: .touchUpInside)
        
        let revenueButton = UIButton(type: .system)
        revenueButton.setTitle("Track Revenue", for: .normal)
        revenueButton.addTarget(self, action: #selector(trackRevenueTapped), for: .touchUpInside)
        
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(eventButton)
        stackView.addArrangedSubview(revenueButton)
        
        view.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])
    }
    
    @objc private func trackEventTapped() {
        datalyrTrack("uikit_button_clicked", properties: [
            "button_type": "event",
            "controller": "ExampleViewController"
        ])
    }
    
    @objc private func trackRevenueTapped() {
        Task {
            await DatalyrSDK.shared.trackRevenue("uikit_purchase", properties: [
                "product": "Premium Upgrade",
                "value": 29.99,
                "currency": "USD"
            ])
        }
    }
}

// MARK: - App Delegate Example

class ExampleAppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        Task {
            do {
                try await DatalyrSDK.configure(
                    workspaceId: "your_workspace_id",
                    apiKey: "your_api_key",
                    debug: true,
                    enableAutoEvents: true,
                    enableAttribution: true
                )
                
                // Enable automatic screen tracking
                DatalyrSDK.enableAutomaticScreenTracking()
                
                print("✅ Datalyr SDK initialized in AppDelegate")
            } catch {
                print("❌ Failed to initialize Datalyr SDK: \(error)")
            }
        }
        
        return true
    }
    
    // Handle deep links for attribution
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        Task {
            await DatalyrSDK.shared.handleDeepLink(url)
        }
        return true
    }
} 