# Datalyr iOS SDK Installation Guide

This guide will walk you through installing and setting up the Datalyr iOS SDK in your iOS application.

## Prerequisites

Before you begin, make sure you have:

- **Xcode 13.0+** installed
- **iOS 13.0+** as your deployment target
- **Swift 5.5+** in your project
- A **Datalyr account** with your workspace ID and API key

## Installation Methods

### Method 1: Swift Package Manager (Recommended)

Swift Package Manager is the easiest way to install the Datalyr iOS SDK.

#### Using Xcode (GUI Method)

1. Open your project in Xcode
2. Go to **File → Add Package Dependencies**
3. In the search field, enter:
   ```
   https://github.com/datalyr/datalyr-ios-sdk
   ```
4. Click **Add Package**
5. Choose the latest version (or specify a version range)
6. Select your target and click **Add Package**

#### Using Package.swift (Command Line Method)

If you're working with a Swift Package, add the dependency to your `Package.swift` file:

```swift
// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [
        .iOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/datalyr/datalyr-ios-sdk", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "YourApp",
            dependencies: [
                .product(name: "DatalyrSDK", package: "datalyr-ios-sdk")
            ]
        )
    ]
)
```

### Method 2: Manual Installation

If you prefer to install manually:

1. Download the latest release from [GitHub Releases](https://github.com/datalyr/datalyr-ios-sdk/releases)
2. Unzip the downloaded file
3. Drag the `DatalyrSDK` folder into your Xcode project
4. Make sure to check "Copy items if needed"
5. Add the SDK to your target's dependencies

## Basic Setup

### Step 1: Import the SDK

In your `AppDelegate.swift` or main app file, import the SDK:

```swift
import DatalyrSDK
```

### Step 2: Get Your Credentials

You'll need two pieces of information from your Datalyr dashboard:

1. **Workspace ID** - Found in your dashboard settings
2. **API Key** - Generated in your workspace settings

### Step 3: Initialize the SDK

Add the initialization code to your app's startup process:

#### For UIKit Apps (AppDelegate)

```swift
import UIKit
import DatalyrSDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Initialize Datalyr SDK
        Task {
            do {
                let config = DatalyrConfig(
                    workspaceId: "YOUR_WORKSPACE_ID",
                    apiKey: "YOUR_API_KEY",
                    debug: false // Set to true during development
                )
                
                try await DatalyrSDK.shared.initialize(config: config)
                print("✅ Datalyr SDK initialized successfully")
            } catch {
                print("❌ Failed to initialize Datalyr SDK: \(error)")
            }
        }
        
        return true
    }
}
```

#### For SwiftUI Apps

```swift
import SwiftUI
import DatalyrSDK

@main
struct YourApp: App {
    
    init() {
        // Initialize Datalyr SDK
        Task {
            do {
                let config = DatalyrConfig(
                    workspaceId: "YOUR_WORKSPACE_ID",
                    apiKey: "YOUR_API_KEY",
                    debug: false
                )
                
                try await DatalyrSDK.shared.initialize(config: config)
                print("✅ Datalyr SDK initialized successfully")
            } catch {
                print("❌ Failed to initialize Datalyr SDK: \(error)")
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

## Configuration Options

### Basic Configuration

For most apps, the basic configuration is sufficient:

```swift
let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY"
)
```

### Advanced Configuration

For more control over the SDK behavior:

```swift
let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY",
    debug: true,                    // Enable debug logging
    maxRetries: 3,                  // Number of retry attempts
    timeout: 30.0,                  // Request timeout in seconds
    batchSize: 20,                  // Events per batch
    flushInterval: 15.0,            // Auto-flush interval in seconds
    maxQueueSize: 1000,             // Maximum events in queue
    enableAutoEvents: true,         // Enable automatic events
    enableAttribution: true         // Enable attribution tracking
)
```

### Auto Events Configuration

To customize automatic event tracking:

```swift
let autoConfig = AutoEventConfig(
    trackSessions: true,        // Track app sessions
    trackScreenViews: true,     // Track screen changes
    trackAppUpdates: true,      // Track app version changes
    trackPerformance: false     // Track performance metrics
)

let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY",
    enableAutoEvents: true,
    autoEventConfig: autoConfig
)
```

## Deep Link Setup (Optional)

If you want to track attribution from deep links, add this to your app:

### For iOS 13+ (SceneDelegate)

```swift
import UIKit
import DatalyrSDK

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        
        // Datalyr automatically processes attribution parameters
        // No additional code needed - just ensure the SDK is initialized
        
        // Handle your app's deep link logic here
        handleDeepLink(url)
    }
    
    private func handleDeepLink(_ url: URL) {
        // Your app's deep link handling logic
    }
}
```

### For iOS 12 and earlier (AppDelegate)

```swift
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    
    // Datalyr automatically processes attribution parameters
    // No additional code needed - just ensure the SDK is initialized
    
    // Handle your app's deep link logic here
    handleDeepLink(url)
    
    return true
}
```

## Verification

### Test Your Installation

Add this test code to verify the SDK is working:

```swift
// In a view controller or SwiftUI view
Task {
    // Track a test event
    await DatalyrSDK.shared.track("test_event", eventData: [
        "installation": "success",
        "timestamp": Date().timeIntervalSince1970
    ])
    
    print("✅ Test event sent!")
}
```

### Enable Debug Mode

During development, enable debug mode to see detailed logs:

```swift
let config = DatalyrConfig(
    workspaceId: "YOUR_WORKSPACE_ID",
    apiKey: "YOUR_API_KEY",
    debug: true  // Enable debug logging
)
```

You should see logs like:
```
[Datalyr] SDK initialized successfully
[Datalyr] Tracking event: test_event
[Datalyr] Event queued: test_event (queue size: 1)
[Datalyr] Event sent successfully: test_event
```

## Troubleshooting

### Common Issues

#### 1. "Module 'DatalyrSDK' not found"
- Make sure you've added the package dependency correctly
- Clean and rebuild your project (⌘+Shift+K, then ⌘+B)
- Check that your deployment target is iOS 13.0+

#### 2. "SDK initialization failed"
- Verify your workspace ID and API key are correct
- Check your internet connection
- Enable debug mode to see detailed error messages

#### 3. "Events not appearing in dashboard"
- Enable debug mode and check for error logs
- Verify your workspace ID and API key
- Check that events are being sent (look for "Event sent successfully" logs)
- Allow a few minutes for events to appear in your dashboard

#### 4. Build errors with Swift Package Manager
- Make sure your Xcode version is 13.0+
- Try resetting package caches: File → Packages → Reset Package Caches
- Clean derived data: ⌘+Shift+K

### Getting Help

If you encounter issues:

1. **Check the logs** - Enable debug mode and look for error messages
2. **Verify credentials** - Double-check your workspace ID and API key
3. **Test network** - Make sure your app can reach the internet
4. **Contact support** - Email support@datalyr.com with your error logs

## Next Steps

Once you have the SDK installed and initialized:

1. **Track your first event** - See the [Quick Start Guide](README.md#quick-start)
2. **Set up screen tracking** - Learn about automatic and manual screen tracking
3. **Implement user identification** - Track user sessions and properties
4. **Configure attribution** - Set up deep link attribution tracking

## Security Notes

- **Never commit your API key** to version control
- **Use environment variables** or secure configuration files for production
- **Enable debug mode only during development**
- **Consider using different workspaces** for development and production

## Example Environment Setup

For production apps, consider using environment-based configuration:

```swift
#if DEBUG
let config = DatalyrConfig(
    workspaceId: "dev_workspace_id",
    apiKey: "dev_api_key",
    debug: true
)
#else
let config = DatalyrConfig(
    workspaceId: "prod_workspace_id",
    apiKey: "prod_api_key",
    debug: false
)
#endif
```

---

**You're all set!** The Datalyr iOS SDK is now installed and ready to track events in your app. 🎉 