import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Who the user is talking to.
///
/// A name and a role, because "Message us" tells someone nothing about whether
/// a human is on the other end. For a small app the honest answer is usually a
/// person — and being told so is most of why anyone writes in at all.
public struct SupportResponder: Sendable, Equatable {
    /// What to show beside the name.
    public enum Avatar: Sendable, Equatable {
        /// The responder's initials on a tinted circle.
        case initials
        /// A drawn face — friendlier than two letters, and no asset to ship.
        case cartoon
    }

    public let name: String
    public let role: String?
    public let avatar: Avatar
    /// Shows a green dot on the avatar.
    ///
    /// The SDK cannot know whether anyone is actually at a keyboard, so this
    /// is the app's claim, not an observation. Set it when it is true —
    /// during your working hours, say — rather than leaving it on forever,
    /// because a permanent green dot beside an unanswered message is worse
    /// than no dot at all.
    public let isOnline: Bool

    /// - Parameters:
    ///   - name: Who replies, e.g. "Sahil".
    ///   - role: What they are to the app, e.g. "Founder". Omitted for none.
    ///   - avatar: Initials by default; `.cartoon` draws a face.
    ///   - isOnline: Whether to show the green dot. Off by default.
    public init(
        name: String,
        role: String? = nil,
        avatar: Avatar = .initials,
        isOnline: Bool = false
    ) {
        self.name = name
        self.role = role
        self.avatar = avatar
        self.isOnline = isOnline
    }

    /// Initials for the avatar, at most two letters.
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

/// One message in a support conversation.
public struct SupportMessage: Identifiable, Equatable, Sendable {
    public enum Sender: String, Sendable {
        /// The person using the app.
        case user
        /// Whoever answers from the dashboard, shown as the app itself.
        case owner
    }

    /// Where a message is in its life. Only outgoing messages are ever
    /// anything but `.sent`: the user needs to see that their question is on
    /// its way, and to know when it did not make it.
    public enum State: String, Sendable {
        case sending
        case sent
        case failed
    }

    public let id: String
    public let sender: Sender
    public let body: String
    public let sentAt: Date
    public internal(set) var state: State
}

/// A message written on this device that has not been accepted by the server
/// yet. Persisted, because the reason a send fails is usually that the app is
/// about to be closed or the network just went.
private struct QueuedMessage: Codable {
    let clientId: String
    let body: String
    let createdAt: Date
}

/// The support conversation for this install.
///
/// Analytics events are fire-and-forget: one lost to a flaky network is a
/// rounding error nobody notices. A support message is not — someone asking
/// about a refund and hearing nothing is worse than never offering chat. So
/// every outgoing message is written to disk first and retried until the
/// server takes it.
@MainActor
public final class SupportChat: ObservableObject {
    /// The conversation, oldest first, including messages still on their way.
    @Published public private(set) var messages: [SupportMessage] = []
    /// Replies the user has not seen. Badge your own Help button with this.
    @Published public private(set) var unreadCount: Int = 0
    /// True while the first load is in flight, so the view can say so.
    @Published public private(set) var isLoading: Bool = false
    /// Set when the user taps a reply notification. The app watches this and
    /// presents the chat — the SDK does not own the navigation, so it asks
    /// rather than pushes a screen into someone else's hierarchy.
    @Published public private(set) var shouldPresent: Bool = false

    /// Who answers, as the dashboard has it. Served with the conversation so
    /// the app does not hardcode a name the owner can change — and so changing
    /// it does not need a release.
    @Published public private(set) var responderName: String?
    @Published public private(set) var responderRole: String?

    /// Whether anything sits above the oldest message held here.
    @Published public private(set) var hasMoreHistory = false
    /// True while a page of older messages is on its way.
    @Published public private(set) var isLoadingHistory = false

    private var reachedStartOfHistory = false

    private var queue: [QueuedMessage] = []
    private var isFlushing = false
    private var isRefreshing = false

    /// True while the conversation is on screen. A reply that lands now needs
    /// no banner: the person is already reading the thread it would announce.
    public private(set) var isOnScreen = false {
        didSet { Self.screenVisibility.set(isOnScreen) }
    }

    /// The same fact, readable without hopping to the main actor.
    ///
    /// iOS shows a foreground notification only if the presentation decision
    /// comes back promptly, so that decision cannot wait on a main thread that
    /// might be mid-render: waiting is indistinguishable from choosing to
    /// show nothing.
    static let screenVisibility = ScreenVisibility()

    final class ScreenVisibility: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set(_ newValue: Bool) {
            lock.lock(); defer { lock.unlock() }
            value = newValue
        }

        var isOnScreen: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private var lastLoadedAt: Date?
    private let session = URLSession.shared

    private let queueURL: URL? = {
        guard
            let dir = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("astronaut-support-queue.json")
    }()

    init() {
        loadQueue()
        // Anything left from a previous run is shown as still sending, so a
        // message never silently disappears between launches.
        messages = queue.map {
            SupportMessage(
                id: $0.clientId,
                sender: .user,
                body: $0.body,
                sentAt: $0.createdAt,
                state: .sending
            )
        }

        // Anything still queued from a previous run goes out now. Waiting for
        // the app to be backgrounded and reopened would strand a message
        // written just before a crash — the case the queue exists for.
        flush()

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Coming back to the app is the moment a reply is most likely
            // waiting, and the moment the network is most likely back.
            MainActor.assumeIsolated {
                self?.refresh()
                self?.flush()
            }
        }
        #endif
    }

    // MARK: - Public API

    /// Send a message from the user. Appears immediately as `.sending`, and
    /// keeps retrying until it lands.
    public func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        let queued = QueuedMessage(
            clientId: UUID().uuidString,
            body: String(body.prefix(2000)),
            createdAt: Date()
        )
        queue.append(queued)
        saveQueue()
        messages.append(
            SupportMessage(
                id: queued.clientId,
                sender: .user,
                body: queued.body,
                sentAt: queued.createdAt,
                state: .sending
            )
        )
        flush()
    }

    /// Re-attempt a message the user was told had failed.
    public func retry(_ message: SupportMessage) {
        guard message.state == .failed else { return }
        markState(of: message.id, to: .sending)
        flush()
    }

    /// Pull the thread from the server. Cheap to call often — it asks only for
    /// what is newer than what it already has.
    public func refresh() {
        // Launch calls this, and so does coming to the foreground — which on a
        // cold start is the same moment. One request is enough.
        guard !isRefreshing, let context = Self.context() else { return }
        isRefreshing = true
        if messages.isEmpty { isLoading = true }

        var components = URLComponents(
            url: AstronautConfiguration.baseURL.appendingPathComponent("/api/support/messages"),
            resolvingAgainstBaseURL: false
        )
        // No device_id: the secret says which conversation this is, and an
        // identifier in a query string is one that ends up in a log.
        var items = [URLQueryItem(name: "tracking_id", value: context.trackingId)]
        if let since = lastLoadedAt {
            items.append(URLQueryItem(name: "since", value: Self.iso8601.string(from: since)))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            isRefreshing = false
            return
        }

        var pull = URLRequest(url: url)
        pull.setValue("Bearer \(context.secret)", forHTTPHeaderField: "Authorization")

        Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.isLoading = false
                    self?.isRefreshing = false
                }
            }
            guard let (data, response) = try? await self?.session.data(for: pull),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            let incoming = (payload["messages"] as? [[String: Any]] ?? [])
                .compactMap(Self.parse)
            let unread = payload["unread"] as? Int ?? 0
            let responder = payload["responder"] as? [String: Any]
            let name = responder?["name"] as? String
            let role = responder?["role"] as? String
            // Only the newest page reports this; a catch-up fetch says nothing
            // about what sits above what is already held.
            let hasMore = payload["has_more"] as? Bool

            await MainActor.run {
                self?.merge(incoming, unread: unread)
                if let hasMore, self?.reachedStartOfHistory == false {
                    self?.hasMoreHistory = hasMore
                }
                // Only ever replaced by something: a server that has no name
                // set should not blank out the app's own fallback.
                if let name, !name.isEmpty { self?.responderName = name }
                if let role, !role.isEmpty { self?.responderRole = role }
            }
        }
    }

    /// The conversation appeared or went away. Drives whether an incoming
    /// reply is announced, so it is the view's business to keep it honest —
    /// `SupportChatView` does this for you.
    public func screenAppeared() {
        isOnScreen = true
    }

    public func screenDisappeared() {
        isOnScreen = false
    }

    /// A conversation the owner started: the notification carried the key to
    /// it, which is the only copy this device will ever be offered.
    ///
    /// Adopting it replaces the key this install was holding — one that owns
    /// no conversation, since nothing has been written from here.
    func adoptSession(_ key: String) {
        guard let trackingId = Astronaut.shared.currentTrackingId else { return }
        SupportSecretStore.adopt(key, for: trackingId)
        // Nothing local can belong to the new conversation.
        messages.removeAll()
        lastLoadedAt = nil
        hasMoreHistory = false
        reachedStartOfHistory = false
        refresh()
    }

    /// Pulls the page before the oldest message on screen.
    ///
    /// Called when the reader reaches the top of the conversation. Quiet about
    /// failure: a page that does not arrive can be asked for again by
    /// scrolling, and an error banner over someone's history helps nobody.
    public func loadOlderMessages() {
        guard hasMoreHistory, !isLoadingHistory,
              let oldest = messages.first,
              let context = Self.context()
        else { return }

        isLoadingHistory = true

        var components = URLComponents(
            url: AstronautConfiguration.baseURL.appendingPathComponent("/api/support/messages"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "tracking_id", value: context.trackingId),
            URLQueryItem(name: "before", value: Self.iso8601.string(from: oldest.sentAt)),
        ]
        guard let url = components?.url else {
            isLoadingHistory = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(context.secret)", forHTTPHeaderField: "Authorization")

        Task { [weak self] in
            defer { Task { @MainActor in self?.isLoadingHistory = false } }

            guard let (data, response) = try? await self?.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            let older = (payload["messages"] as? [[String: Any]] ?? []).compactMap(Self.parse)
            let hasMore = payload["has_more"] as? Bool ?? false

            await MainActor.run {
                guard let self else { return }
                self.prepend(older.map(\.message))
                self.hasMoreHistory = hasMore
                // The newest page cannot tell us this, so remember it.
                if !hasMore { self.reachedStartOfHistory = true }
            }
        }
    }

    /// Older messages, in front of what is already held.
    private func prepend(_ older: [SupportMessage]) {
        guard !older.isEmpty else { return }
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in older where byId[message.id] == nil {
            byId[message.id] = message
        }
        messages = byId.values.sorted { $0.sentAt < $1.sentAt }
    }

    /// The responder to show, given what the app supplied as a fallback.
    ///
    /// The dashboard owns the name and role; the app owns how it looks. An
    /// app that passes nothing gets the dashboard's identity with a plain
    /// avatar, and one that passes a responder keeps its avatar and online
    /// dot while the name follows the dashboard.
    public func resolvedResponder(fallback: SupportResponder?) -> SupportResponder? {
        guard let name = responderName ?? fallback?.name else { return nil }
        return SupportResponder(
            name: name,
            role: responderRole ?? fallback?.role,
            avatar: fallback?.avatar ?? .initials,
            isOnline: fallback?.isOnline ?? false
        )
    }

    /// A support notification arrived — tapped, or shown while the app was
    /// open.
    ///
    /// The notification already carries the message, so it goes on screen
    /// immediately under the id the server stored it as. Waiting for the fetch
    /// instead left an empty conversation for as long as the network took,
    /// which on a cold launch is seconds of looking at nothing.
    func notificationArrived(sessionKey: String?, messageId: String?, body: String?) {
        if let sessionKey { adoptSession(sessionKey) }

        if let messageId, let body,
           !messages.contains(where: { $0.id == messageId }) {
            messages.append(
                SupportMessage(
                    id: messageId,
                    sender: .owner,
                    body: body,
                    // The real timestamp comes with the fetch; until then, now
                    // is close enough and keeps it last in the conversation.
                    sentAt: Date(),
                    state: .sent
                )
            )
            unreadCount += 1
        }

        refresh()
    }

    /// A reply notification was tapped. Asks the app to show the chat, and
    /// fetches the reply so it is already there when the screen opens.
    public func notificationTapped() {
        shouldPresent = true
        refresh()
    }

    /// Call once the chat has been presented, so it is not shown again on the
    /// next state change.
    public func presentationHandled() {
        shouldPresent = false
    }

    /// The user has seen the conversation. Clears their badge on the server so
    /// it does not follow them to another launch.
    public func markRead() {
        guard unreadCount > 0, let context = Self.context() else { return }
        unreadCount = 0
        post(
            path: "/api/support/read",
            payload: ["tracking_id": context.trackingId],
            secret: context.secret
        )
    }

    // MARK: - Sending

    /// Sends the oldest queued message, then the next. One at a time, so the
    /// conversation keeps the order it was written in.
    private func flush() {
        guard !isFlushing, let next = queue.first, let context = Self.context() else { return }
        isFlushing = true

        let body: [String: Any] = [
            "tracking_id": context.trackingId,
            "device_id": context.deviceId,
            "body": next.body,
            "client_id": next.clientId,
        ]
        guard
            let url = URL(string: "/api/support/messages", relativeTo: AstronautConfiguration.baseURL),
            let data = try? JSONSerialization.data(withJSONObject: body)
        else {
            isFlushing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(context.secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        Task { [weak self] in
            let status: Int
            var storedMessage: SupportMessage?
            if let (data, response) = try? await self?.session.data(for: request) {
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let row = payload["message"] as? [String: Any] {
                    storedMessage = Self.parse(row)?.message
                }
            } else {
                status = 0
            }

            await MainActor.run {
                guard let self else { return }
                self.isFlushing = false

                if status == 200 {
                    // Accepted — including a retry the server recognised as a
                    // duplicate, which it answers with the message it already
                    // stored rather than an error.
                    self.queue.removeAll { $0.clientId == next.clientId }
                    self.saveQueue()
                    // Take the server's id for this message. Keeping the local
                    // client id would leave the same message under two ids, and
                    // the next refresh would show it twice.
                    if let stored = storedMessage {
                        self.adopt(stored, replacing: next.clientId)
                    } else {
                        self.markState(of: next.clientId, to: .sent)
                    }
                    self.flush()
                } else if (400..<500).contains(status) && status != 429 {
                    // The server will never accept this one — too long, or an
                    // app that no longer exists. Retrying forever would hide
                    // the problem from the person waiting for an answer.
                    self.queue.removeAll { $0.clientId == next.clientId }
                    self.saveQueue()
                    self.markState(of: next.clientId, to: .failed)
                } else {
                    // Network, rate limit, or the server having a moment: keep
                    // it queued and try again when the app next comes forward.
                    self.markState(of: next.clientId, to: .sending)
                }
            }
        }
    }

    private func post(path: String, payload: [String: Any], secret: String) {
        guard
            let url = URL(string: path, relativeTo: AstronautConfiguration.baseURL),
            let data = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        session.dataTask(with: request).resume()
    }

    // MARK: - State

    private func merge(_ incoming: [(message: SupportMessage, clientId: String?)], unread: Int) {
        guard !incoming.isEmpty || unreadCount != unread else { return }
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        for item in incoming {
            byId[item.message.id] = item.message
            // The same message, still filed locally under the id this device
            // gave it. Matched on client_id rather than on the text, so two
            // messages that happen to say "Hi" stay two messages.
            if let clientId = item.clientId {
                byId.removeValue(forKey: clientId)
            }
        }

        messages = byId.values.sorted { $0.sentAt < $1.sentAt }
        unreadCount = unread
        lastLoadedAt = incoming.map(\.message.sentAt).max() ?? lastLoadedAt
    }

    /// Replaces a locally-keyed message with the one the server stored.
    private func adopt(_ stored: SupportMessage, replacing clientId: String) {
        if let index = messages.firstIndex(where: { $0.id == clientId }) {
            messages[index] = stored
        } else if !messages.contains(where: { $0.id == stored.id }) {
            messages.append(stored)
        }
    }

    private func markState(of id: String, to state: SupportMessage.State) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].state = state
    }

    // MARK: - Disk

    private func loadQueue() {
        guard let url = queueURL, let data = try? Data(contentsOf: url) else { return }
        queue = (try? JSONDecoder().decode([QueuedMessage].self, from: data)) ?? []
    }

    private func saveQueue() {
        guard let url = queueURL else { return }
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    /// What every request needs: which app, which install, and the secret that
    /// owns the conversation. No secret, no chat — the routes refuse an
    /// unauthenticated caller, and so should we before making the trip.
    private static func context() -> (trackingId: String, deviceId: String, secret: String)? {
        guard
            let trackingId = Astronaut.shared.currentTrackingId,
            let secret = SupportSecretStore.secret(for: trackingId)
        else { return nil }
        return (trackingId, Astronaut.shared.deviceId.uuidString, secret)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parse(
        _ row: [String: Any]
    ) -> (message: SupportMessage, clientId: String?)? {
        guard
            let id = row["id"] as? String,
            let senderRaw = row["sender"] as? String,
            let sender = SupportMessage.Sender(rawValue: senderRaw),
            let body = row["body"] as? String,
            let sentAtRaw = row["sent_at"] as? String
        else { return nil }

        // Postgres hands back microseconds and a "+00:00" offset; the plain
        // formatter rejects the fractional part, so try both before giving up
        // on a message that is otherwise perfectly readable.
        let sentAt = iso8601.date(from: sentAtRaw)
            ?? ISO8601DateFormatter().date(from: sentAtRaw)
            ?? Self.postgres.date(from: sentAtRaw)
            ?? Date()

        return (
            SupportMessage(id: id, sender: sender, body: body, sentAt: sentAt, state: .sent),
            row["client_id"] as? String
        )
    }

    private static let postgres: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return f
    }()
}
