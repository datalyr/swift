# 🧪 Datalyr iOS SDK Test App

A comprehensive debug and test application for the Datalyr iOS SDK - similar to the React Native test app.

## 🎯 What This Tests

- ✅ **SDK Initialization** - Complete configuration with debug logging
- ✅ **Real-time Status** - Live SDK status monitoring  
- ✅ **Event Tracking** - Various event types with properties
- ✅ **User Management** - Login, logout, profile updates
- ✅ **Attribution Testing** - Deep link simulation and testing
- ✅ **Offline Support** - Event queueing when offline
- ✅ **Live Logging** - Recent activity logs in the app
- ✅ **Debug Console** - Detailed console output

## 📱 Features

### 📊 SDK Status Dashboard
- Initialization status
- Workspace configuration
- Visitor & session IDs
- Event queue size
- Current user info

### 🧪 Event Testing Buttons
- **Simple Event** - Basic event tracking
- **Page View** - Screen navigation events
- **Purchase** - E-commerce event with properties
- **Button Click** - User interaction events
- **Error Event** - Error tracking
- **Custom Event** - Custom event with data

### 🔗 Attribution Testing
- **UTM Test** - UTM parameter simulation
- **Facebook Click** - Facebook click ID testing
- **Google Click** - Google click ID testing  
- **LYR Tag** - Datalyr LYR tag testing

### ⚙️ SDK Management
- **Flush Queue** - Force send queued events
- **Reset User** - Clear user session
- **Get Attribution** - Show current attribution data
- **Test Offline** - Simulate offline event queueing

## 🚀 Quick Setup

1. **Open in Xcode**
   - Open `DatalyrTestApp.xcodeproj` in Xcode
   - Or use the existing BasicExample.swift

2. **Update Configuration**
   ```swift
   try await DatalyrSDK.configure(
       workspaceId: "your_workspace_id", // 👈 Change this!
       apiKey: "dk_your_api_key",        // 👈 Change this!
       debug: true,
       enableAutoEvents: true,
       enableAttribution: true
   )
   ```

3. **Build & Run**
   - Select iOS Simulator or device
   - Press ⌘+R to build and run

## 🔧 Testing Workflow

### 1. Verify SDK Status
- Check that "Initialized" shows ✅ Yes
- Verify your workspace ID appears
- Note the visitor ID (stays same across sessions)

### 2. Test Basic Events
- Tap "Simple Event" to send basic event
- Check console logs for network requests
- Event counter should increment

### 3. Test User Management
- Enter a username and tap "Login"
- User ID should appear in SDK Status
- Try "Update Profile" and "Logout"

### 4. Test Attribution
- Tap UTM Test, Facebook Click, etc.
- Check "Get Attribution" to see captured data
- Attribution data persists across app launches

### 5. Test Offline Mode
- Tap "Test Offline" (simulates network failure)
- Events queue up (see Queue Size in status)
- Tap "Flush Queue" to send when back online

## 📊 Monitoring Results

### In the App
- **Recent Logs** section shows last 5 activities
- **SDK Status** shows real-time queue and user state
- **Event Counter** tracks total events sent

### In Xcode Console
```bash
✅ Datalyr SDK initialized successfully
📊 Tracked: simple_event
🔗 Simulated deep link: utm_source=facebook&utm_campaign=test
🚀 Events flushed to server
```

### In Datalyr Dashboard
Events appear with:
- `source: "ios_app"`
- Device fingerprint data
- Attribution parameters  
- Session information
- All custom properties

## 🔗 Deep Link Testing

Test attribution in iOS Simulator:

```bash
# UTM Parameters
xcrun simctl openurl booted "datalyr-test://test?utm_source=facebook&utm_campaign=summer_sale"

# Facebook Click ID  
xcrun simctl openurl booted "datalyr-test://test?fbclid=IwAR123456789"

# Multiple Parameters
xcrun simctl openurl booted "datalyr-test://test?utm_source=google&gclid=abc123&dl_tag=test"
```

## 🏗️ Project Structure

```
test-app/
├── README.md                     # This file
├── DatalyrTestApp/
│   └── ContentView.swift         # Complete test app in one file
└── Package.swift                 # Swift Package config (if needed)
```

## 🐛 Troubleshooting

**"Not Initialized" Status:**
- Check that workspaceId and apiKey are set
- Look for initialization errors in console
- Verify network connectivity

**Events Not Sending:**
- Enable debug mode to see network logs
- Check event queue size (should decrease after flush)
- Verify API key format: `dk_your_api_key`

**Attribution Not Working:**
- Test deep links in simulator with xcrun commands
- Check Recent Logs for "Simulated deep link" messages
- Use "Get Attribution" button to see captured data

**Build Errors:**
- Ensure iOS 15+ deployment target
- Check that DatalyrSDK dependency is resolved
- Clean build folder (⇧⌘K) and rebuild

## 📈 What to Expect

### Events in Dashboard
```json
{
  "event_name": "simple_event", 
  "source": "ios_app",
  "visitor_id": "12345678-1234-1234-1234-123456789012",
  "session_id": "87654321-4321-4321-4321-210987654321",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "device_info": {
    "model": "iPhone 15 Pro",
    "os_version": "17.0",
    "screen_size": "393x852"
  }
}
```

### Attribution Data
```json
{
  "utm_source": "facebook",
  "utm_campaign": "summer_sale", 
  "fbclid": "IwAR123456789",
  "attribution_timestamp": "2024-01-15T10:30:00.000Z"
}
```

## 📧 Support

- **Issues**: [GitHub Issues](https://github.com/datalyr/datalyr-ios-sdk/issues)
- **Email**: support@datalyr.com
- **Docs**: https://docs.datalyr.com

---

**🎯 This test app demonstrates the complete iOS SDK functionality in a single, easy-to-use interface - just like the React Native version!** 