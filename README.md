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

### Chat (optional)

A conversation between the user and you, keyed to the same install the events
come from. Present it anywhere:

```swift
.sheet(isPresented: $showingHelp) {
    Astronaut.shared.chatView(
        tint: .orange,
        placeholder: "What's up?",
        // Optional. Shown above the conversation, so people know who replies.
        // `.cartoon` draws a face instead of initials; isOnline adds a green
        // dot — your claim, not something the SDK can observe, so set it when
        // it is true rather than leaving it on.
        responder: ChatResponder(
            name: "Sahil",
            role: "Founder",
            avatar: .cartoon,
            isOnline: true
        )
    )
}
```

A reply that arrives while the conversation is open is not announced — it
simply appears. If you build your own chat UI instead of `chatView`, call
`Astronaut.shared.chat.screenAppeared()` / `.screenDisappeared()` to get the
same behaviour.

The conversation is owned by a key the SDK generates and stores on the device,
sent as a bearer token on every request — a device id is never accepted as
proof of ownership. The app tells the server the hash of that key on first run,
which is what lets you start a conversation with someone who has never written
to you. Nothing to configure.

To put the identity in the navigation bar instead of above the conversation,
pass `showsResponderHeader: false` and place `ChatResponderLabel` in your
own toolbar — it lines up with the close button that way.

Opening the conversation sends a `chat_opened` event, with the `source` you
pass as metadata — so the journey shows which screen sent someone looking for
help, the paywall included.

`Astronaut.shared.chat.unreadCount` drives a badge, and
`Astronaut.shared.refreshChat()` at launch keeps it current. Replies arrive
as push notifications under your own app's name; tapping one opens the chat.

## Requirements

- iOS 16+
- Swift 5.9+
