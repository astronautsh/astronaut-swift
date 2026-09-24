import Foundation
import UserNotifications
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct AstronautConfiguration {
    /// Fixed astronaut.sh ingest endpoint — same for every app, so it's not a
    /// caller-supplied option. (The apex astronaut.sh 308-redirects to www.)
    static let baseURL = URL(string: "https://www.astronaut.sh")!

    /// Public app identifier (trk_...) from the astronaut.sh dashboard. Required:
    /// it's how the backend attributes your events to your app.
    public let trackingId: String

    /// When nil, derived from the build: `sandbox` in DEBUG; otherwise `sandbox`
    /// when the App Store receipt is a sandbox receipt (TestFlight / App Review),
    /// else `release` (the live App Store). Set explicitly to override.
    public let releaseEnvironment: String?

    public init(trackingId: String, releaseEnvironment: String? = nil) {
        self.trackingId = trackingId
        self.releaseEnvironment = releaseEnvironment
    }
}

public final class Astronaut {
    public static let shared = Astronaut()

    /// ISO 8601 with millisecond fractional seconds (UTC), for `event_time`.
    private static let iso8601Millis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Hardware identifier, e.g. "iPhone16,2" — the raw utsname value, not a
    /// marketing name. Mapping identifiers to "iPhone 15 Pro Max" needs a table
    /// that is wrong for every device released after the SDK shipped, so the
    /// dashboard receives the accurate opaque string and decides for itself.
    ///
    /// Computed once: uname(3) is a syscall, and every event would repeat it.
    private static let deviceModel: String = {
        // On a simulator, uname reports the Mac's own architecture ("arm64"),
        // which would land in the data as if it were a real device. The
        // simulator advertises the device it is pretending to be here instead.
        if let simulated = ProcessInfo.processInfo
            .environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }

        var systemInfo = utsname()
        uname(&systemInfo)

        // `machine` is a fixed-size C char array bridged as a tuple: read it as
        // raw bytes and stop at the first NUL, or the string carries the array's
        // trailing padding.
        return withUnsafeBytes(of: systemInfo.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    /// Bumped when first-open semantics changed; avoids a stale `true` from older builds.
    private let hasSentFirstAppOpenKey = "ma_has_sent_first_app_open"
    private let defaults = UserDefaults.standard

    private var configuration: AstronautConfiguration?
    private let deviceUUID: UUID
    private let foregroundPresenter = ForegroundNotificationPresenter()

    /// Stable per-install identifier — the `device_id` attached to every event.
    ///
    /// Exposed as a `UUID` because that is what StoreKit's `appAccountToken`
    /// requires; Apple silently drops the token if it is anything else. Passing
    /// this on a purchase is what lets verified subscription revenue be
    /// attributed back to the user and the source that acquired them:
    ///
    /// ```swift
    /// let result = try await product.purchase(options: [
    ///     .appAccountToken(Astronaut.shared.deviceId)
    /// ])
    /// ```
    public var deviceId: UUID { deviceUUID }

    /// The configured app, for other parts of the SDK. Internal: callers
    /// already know their own tracking id, and nothing outside needs it.
    var currentTrackingId: String? { configuration?.trackingId }

    /// This install's support conversation — messages, unread count, and the
    /// retry queue that makes a question survive a dropped network.
    ///
    /// Badge your own Help button with `unreadCount`, and present
    /// `supportView()` when it is tapped.
    @MainActor
    public private(set) lazy var support = SupportChat()

    /// Replies the user has not read yet. Call `refreshSupport()` on launch to
    /// bring it up to date before anyone opens the chat.
    @MainActor
    public var unreadSupportCount: Int { support.unreadCount }

    /// Check for new replies. Safe to call on launch and when the app comes
    /// forward; the chat screen keeps itself up to date on its own.
    @MainActor
    public func refreshSupport() {
        support.refresh()
    }

    #if canImport(SwiftUI)
    /// The drop-in support screen, tinted to match the app.
    @available(iOS 16.0, *)
    @MainActor
    public func supportView(
        tint: SwiftUI.Color = .accentColor,
        placeholder: String = "Ask us anything…",
        responder: SupportResponder? = nil,
        showsResponderHeader: Bool = true,
        source: String? = nil
    ) -> some SwiftUI.View {
        SupportChatView(
            chat: support,
            tint: tint,
            placeholder: placeholder,
            responder: responder,
            showsResponderHeader: showsResponderHeader,
            source: source
        )
    }
    #endif

    private init() {
        // Ids have always been persisted as `UUID().uuidString`, so an existing
        // install parses cleanly and keeps the id it has been reporting. Only a
        // missing or unreadable value mints a new one.
        if let existing = defaults.string(forKey: "ma_device_id"),
           let parsed = UUID(uuidString: existing) {
            deviceUUID = parsed
        } else {
            let generated = UUID()
            defaults.set(generated.uuidString, forKey: "ma_device_id")
            deviceUUID = generated
        }
    }

    public func configure(_ configuration: AstronautConfiguration) {
        self.configuration = configuration
        // Installed here, not only when permission is requested: a tap on a
        // reply launches the app cold, and the delegate has to be in place
        // before iOS delivers that tap.
        //
        // Guarded because UNUserNotificationCenter asserts when there is no app
        // bundle around it — which is exactly the case inside a unit-test
        // process, where there are no notifications to deliver anyway.
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = foregroundPresenter
        }
    }

    public func trackAppOpen() {
        let isFirstOpen: Bool
        if defaults.bool(forKey: hasSentFirstAppOpenKey) {
            isFirstOpen = false
        } else {
            defaults.set(true, forKey: hasSentFirstAppOpenKey)
            isFirstOpen = true
        }

        send(
            eventType: "app_open",
            metadata: ["platform": "ios"],
            isFirstOpen: isFirstOpen
        )
    }

    public func trackPurchase(
        revenue: Double,
        currency: String,
        metadata: [String: String] = [:]
    ) {
        send(
            eventType: "purchase",
            metadata: metadata,
            revenue: revenue,
            currency: currency
        )
    }

    /// Reports that a free trial started. Call it when the trial begins, not
    /// when it converts — the conversion is a purchase.
    ///
    /// The event name is fixed here rather than left to each app, so the
    /// dashboard's trials metric works without per-app configuration. Carries
    /// no revenue: a trial is free, and sending 0 would make it indistinguishable
    /// from a zero-value purchase.
    ///
    /// Apps with a verified revenue connection can ignore this — trials are
    /// derived from the store's own record there, which also catches trials
    /// that lapse without ever reaching your code.
    ///
    /// - Parameters:
    ///   - price: What the customer will be charged if the trial converts.
    ///     Reported as potential revenue, never as revenue — nothing has been
    ///     collected yet, and most trials never convert. Pass the product's
    ///     price, not 0.
    ///   - currency: ISO 4217 code for `price`.
    public func trackTrialStart(
        productId: String? = nil,
        price: Double? = nil,
        currency: String? = nil,
        metadata: [String: String] = [:]
    ) {
        var payload = metadata
        if let productId, !productId.isEmpty {
            payload["product_id"] = productId
        }
        // Deliberately metadata rather than the revenue field: revenue is money
        // that changed hands, and every total built on it stays truthful only
        // if a trial contributes nothing.
        if let price {
            payload["potential_price"] = String(price)
        }
        if let currency, !currency.isEmpty {
            payload["potential_currency"] = currency.uppercased()
        }
        send(eventType: "trial_started", metadata: payload)
    }

    /// Associates a real end-user identity with this device so the dashboard can
    /// show a name/email on the user journey instead of an anonymous handle.
    /// Call it once you know who the user is (e.g. after sign-in). The latest
    /// call wins. Only send identity you have a lawful basis to process.
    public func identify(
        email: String? = nil,
        name: String? = nil,
        traits: [String: String] = [:]
    ) {
        guard let configuration else { return }

        var payload: [String: Any] = [
            "device_id": deviceUUID.uuidString,
            "tracking_id": configuration.trackingId,
            "traits": traits,
        ]
        if let email, !email.isEmpty { payload["email"] = email }
        if let name, !name.isEmpty { payload["name"] = name }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }

        var request = URLRequest(
            url: AstronautConfiguration.baseURL.appendingPathComponent("/api/identify")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Prompts for notification permission and, once granted, registers with
    /// APNs. The resulting device token is delivered to the app delegate's
    /// `didRegisterForRemoteNotificationsWithDeviceToken`, which should forward it
    /// to `handleRemoteNotificationRegistration(deviceToken:)`.
    public func requestPushAuthorization(
        options: UNAuthorizationOptions = [.alert, .badge, .sound]
    ) {
        // Without a delegate, iOS suppresses notification banners while the app
        // is in the foreground. This presenter shows them anyway.
        UNUserNotificationCenter.current().delegate = foregroundPresenter
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, _ in
            guard granted else { return }
            #if os(iOS)
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
            #endif
        }
    }

    /// Forward this from the app delegate's
    /// `didRegisterForRemoteNotificationsWithDeviceToken`. Resolves the current
    /// authorization status and stores the token.
    public func handleRemoteNotificationRegistration(
        deviceToken: Data
    ) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            self.registerPushToken(
                deviceToken: deviceToken,
                permissionStatus: Self.permissionStatusString(settings.authorizationStatus)
            )
        }
    }

    /// Maps a `UNAuthorizationStatus` to the `permission_status` value the
    /// analytics backend accepts.
    private static func permissionStatusString(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        @unknown default: return "not_determined"
        }
    }

    /// Register (or update) this device's APNs token after the user responds to
    /// the notification permission prompt. Upserts server-side keyed by device,
    /// so a rotated token replaces the previous one. `permissionStatus` is one of
    /// authorized / provisional / ephemeral / denied / not_determined.
    public func registerPushToken(
        deviceToken: Data,
        permissionStatus: String
    ) {
        guard let configuration else {
            return
        }

        let apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()

        // APNs tokens are environment-specific: debug builds register against the
        // sandbox gateway, release builds against production.
        let apnsEnvironment: String
        #if DEBUG
        apnsEnvironment = "sandbox"
        #else
        apnsEnvironment = "production"
        #endif

        var payload: [String: Any] = [
            "device_id": deviceUUID.uuidString,
            "apns_token": apnsToken,
            "apns_environment": apnsEnvironment,
            "permission_status": permissionStatus,
            "tracking_id": configuration.trackingId,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }

        var request = URLRequest(
            url: AstronautConfiguration.baseURL.appendingPathComponent("/api/push-tokens")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request).resume()
    }

    public func send(
        eventType: String,
        metadata: [String: String],
        revenue: Double? = nil,
        currency: String? = nil,
        isFirstOpen: Bool = false
    ) {
        guard let configuration else {
            return
        }

        let normalizedEventType = eventType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var payload: [String: Any] = [
            "event_type": normalizedEventType,
            "device_id": deviceUUID.uuidString,
            "metadata": metadata,
            "tracking_id": configuration.trackingId,
            // Occurrence time, stamped now (ms, UTC). The backend records this as
            // the event time and stamps its own received_at separately; if this
            // is missing/invalid it falls back to the server receipt time.
            "event_time": Self.iso8601Millis.string(from: Date()),
        ]

        if let region = Locale.current.region?.identifier, !region.isEmpty {
            payload["locale_region"] = region
        }

        payload["timezone"] = TimeZone.current.identifier

        // App's marketing version (CFBundleShortVersionString, e.g. "2.3.1") so
        // events can be segmented/debugged by release.
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !appVersion.isEmpty {
            payload["app_version"] = appVersion
        }

        if !Self.deviceModel.isEmpty {
            payload["device_model"] = Self.deviceModel
        }

        let releaseEnvironment: String
        if let custom = configuration.releaseEnvironment, !custom.isEmpty {
            releaseEnvironment = custom
        } else {
            // Two buckets, not three: "release" is real usage, "sandbox" is
            // everything else — local builds, TestFlight, App Review. They are
            // all non-production traffic that must stay out of your figures, and
            // splitting them further bought nothing. It also matches what store
            // purchases can report: Apple tells us SANDBOX or PRODUCTION and has
            // no idea how a build was compiled, so a three-way split could never
            // apply to revenue.
            #if DEBUG
            releaseEnvironment = "sandbox"
            #else
            if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
                releaseEnvironment = "sandbox"
            } else {
                releaseEnvironment = "release"
            }
            #endif
        }
        payload["release_environment"] = releaseEnvironment

        if let revenue {
            payload["revenue"] = revenue
        }

        if let currency, !currency.isEmpty {
            payload["currency"] = currency
        }

        if normalizedEventType == "app_open" {
            payload["is_first_open"] = isFirstOpen ? 1 : 0
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }

        var request = URLRequest(
            url: AstronautConfiguration.baseURL.appendingPathComponent("/api/events")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request).resume()
    }
}

/// Handles notifications on the SDK's behalf: shows them while the app is in
/// the foreground — iOS delivers them silently otherwise — and routes a tap on
/// a support reply back to the conversation it belongs to.
private final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        guard Self.isSupportReply(userInfo) else {
            completionHandler([.banner, .list, .sound, .badge])
            return
        }

        Task { @MainActor in
            let chat = Astronaut.shared.support
            // On screen by the time the notification would have mentioned it.
            chat.notificationArrived(
                sessionKey: Self.sessionKey(userInfo),
                messageId: Self.messageId(userInfo),
                body: notification.request.content.body
            )

            // Nobody needs to be told about a message they are looking at.
            // Still delivered, so the unread count and the thread stay right —
            // only the banner and the sound are dropped.
            completionHandler(chat.isOnScreen ? [] : [.banner, .list, .sound, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard Self.isSupportReply(userInfo) else { return }

        Task { @MainActor in
            // The message is in the notification, so the conversation opens
            // with it rather than empty while a fetch runs — which on a cold
            // launch is the difference between a blank screen and a chat.
            Astronaut.shared.support.notificationArrived(
                sessionKey: Self.sessionKey(userInfo),
                messageId: Self.messageId(userInfo),
                body: response.notification.request.content.body
            )
            // The app decides how to show it — this only says that it should.
            Astronaut.shared.support.notificationTapped()
        }
    }

    /// A reply sent by the dashboard carries this marker beside `aps`. Anything
    /// else — a campaign push, another SDK's notification — is left alone.
    private static func isSupportReply(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let astronaut = userInfo["astronaut"] as? [String: Any] else { return false }
        return astronaut["type"] as? String == "support"
    }

    /// The id the message was stored under, so the copy taken from the
    /// notification is recognised as the same one when the fetch lands.
    private static func messageId(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let astronaut = userInfo["astronaut"] as? [String: Any],
              let id = astronaut["message_id"] as? String,
              !id.isEmpty
        else { return nil }
        return id
    }

    /// The key to a conversation the owner started, when this notification is
    /// opening one.
    private static func sessionKey(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let astronaut = userInfo["astronaut"] as? [String: Any],
              let key = astronaut["session"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }
}
