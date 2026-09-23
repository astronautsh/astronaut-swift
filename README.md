# Astronaut (Swift)

Official iOS SDK for [astronaut.sh](https://www.astronaut.sh) — mobile app
analytics, attribution, and push-token registration.

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and enter the repository URL, or
add to your `Package.swift`:

```swift
.package(url: "https://github.com/sahil-malhotra/astronaut-swift.git", from: "1.0.1")
```

## Usage

Configure once at launch with your app's **tracking id** (from the astronaut.sh
dashboard → your app), then track events.

```swift
import Astronaut

// In your App init / AppDelegate didFinishLaunching:
Astronaut.shared.configure(
    AstronautConfiguration(trackingId: "trk_xxxxxxxxxxxxxxxx")
)

Astronaut.shared.trackAppOpen()
Astronaut.shared.trackPurchase(revenue: 9.99, currency: "USD")
Astronaut.shared.send(eventType: "level_completed", appUserId: nil, metadata: ["level": "3"])
```

### Push notifications (optional)

```swift
// Request permission + register for remote notifications:
Astronaut.shared.requestPushAuthorization()

// Forward the APNs token from your AppDelegate:
func application(_ application: UIApplication,
                didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Astronaut.shared.handleRemoteNotificationRegistration(deviceToken: deviceToken)
}
```

### Support chat (optional)

A conversation between the user and you, keyed to the same install the events
come from. Present it anywhere:

```swift
.sheet(isPresented: $showingHelp) {
    Astronaut.shared.supportView(
        tint: .orange,
        placeholder: "What's up?",
        // Optional. Shown above the conversation, so people know who replies.
        responder: SupportResponder(name: "Sahil", role: "Founder")
    )
}
```

`Astronaut.shared.support.unreadCount` drives a badge, and
`Astronaut.shared.refreshSupport()` at launch keeps it current. Replies arrive
as push notifications under your own app's name; tapping one opens the chat.

## Requirements

- iOS 16+
- Swift 5.9+
