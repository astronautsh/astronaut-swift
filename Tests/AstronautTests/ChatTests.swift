import XCTest
@testable import Astronaut

/// Tests for the part of chat that cannot be checked by eye: what
/// happens to a message when the network is against it. The queue is the
/// reason chat can promise delivery at all, so its behaviour is pinned here.
@MainActor
final class ChatTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        Astronaut.shared.configure(AstronautConfiguration(trackingId: "naut_test"))
        removeQueueFile()
        removeStoredSecret()
        Chat.hasRegisteredThisLaunch = false
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        removeQueueFile()
        removeStoredSecret()
        try await super.tearDown()
    }

    /// The message appears straight away, marked as on its way, and is on disk
    /// before the request is even attempted — a send must survive the app
    /// being closed a second later.
    func testSendShowsImmediatelyAndPersists() async throws {
        StubURLProtocol.respond(status: 200, body: #"{"message":{"id":"m1"}}"#)
        let chat = Chat()

        chat.send("my watch won't connect")

        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertEqual(chat.messages.first?.body, "my watch won't connect")
        XCTAssertEqual(chat.messages.first?.sender, .user)
        XCTAssertTrue(queueFileExists(), "a queued message must be on disk before the request")

        try await waitUntil { chat.messages.first?.state == .sent }
        XCTAssertFalse(queueFileExists(), "an accepted message should leave the queue")
    }

    /// A refused message — too long, unknown app — must stop retrying and say
    /// so, rather than sit in the queue forever pretending to send.
    func testPermanentRejectionSurfacesAsFailed() async throws {
        StubURLProtocol.respond(status: 400, body: #"{"error":"body is required"}"#)
        let chat = Chat()

        chat.send("x")

        try await waitUntil { chat.messages.first?.state == .failed }
        XCTAssertFalse(queueFileExists(), "a rejected message should not be retried forever")
    }

    /// A network blip keeps the message queued and still showing as sending,
    /// so the next launch can try again.
    func testNetworkFailureKeepsMessageQueued() async throws {
        StubURLProtocol.failWithNetworkError()
        let chat = Chat()

        chat.send("are you there?")

        try await waitUntil { StubURLProtocol.requestCount >= 1 }
        XCTAssertEqual(chat.messages.first?.state, .sending)
        XCTAssertTrue(queueFileExists(), "an unsent message must outlive the launch")
    }

    /// Rate limiting is temporary, so it is treated like a network failure
    /// rather than a rejection: the message stays and tries again later.
    func testRateLimitKeepsMessageQueued() async throws {
        StubURLProtocol.respond(status: 429, body: #"{"error":"Too many messages."}"#)
        let chat = Chat()

        chat.send("hello?")

        try await waitUntil { StubURLProtocol.requestCount >= 1 }
        XCTAssertEqual(chat.messages.first?.state, .sending)
        XCTAssertTrue(queueFileExists())
    }

    /// A message written on a previous launch is restored, still marked as
    /// sending, so nothing silently disappears between runs.
    func testQueueSurvivesRelaunch() async throws {
        StubURLProtocol.failWithNetworkError()
        let first = Chat()
        first.send("written before the crash")
        try await waitUntil { StubURLProtocol.requestCount >= 1 }

        StubURLProtocol.respond(status: 200, body: #"{"message":{"id":"m1"}}"#)
        let second = Chat()

        XCTAssertEqual(second.messages.first?.body, "written before the crash")
        try await waitUntil { second.messages.first?.state == .sent }
    }

    /// Replies from the server land in the conversation, including the
    /// microsecond timestamps Postgres returns.
    func testRefreshParsesServerMessages() async throws {
        StubURLProtocol.respond(
            status: 200,
            body: #"""
            {"messages":[
              {"id":"s1","sender":"user","body":"hi","client_id":null,"sent_at":"2026-09-23T10:00:00.123456+00:00","read_at":null},
              {"id":"s2","sender":"owner","body":"we're on it","client_id":null,"sent_at":"2026-09-23T10:05:00.500000+00:00","read_at":null}
            ],"unread":1}
            """#
        )
        let chat = Chat()

        chat.refresh()

        try await waitUntil { chat.messages.count == 2 }
        XCTAssertEqual(chat.messages.map(\.sender), [.user, .owner])
        XCTAssertEqual(chat.unreadCount, 1)
        XCTAssertLessThan(
            chat.messages[0].sentAt,
            chat.messages[1].sentAt,
            "messages must keep the order they were written in"
        )
    }

    /// The bug found on a real phone: one "Hi" typed, two shown. The message
    /// was filed under the id this device made up, the server's copy came back
    /// under its own id, and nothing tied the two together.
    func testSentMessageIsNotDuplicatedByARefresh() async throws {
        // A response the SDK cannot learn the stored id from, so the local copy
        // keeps its client id — the case the merge has to survive.
        StubURLProtocol.respond(status: 200, body: "{}")
        let chat = Chat()

        chat.send("Hi")
        try await waitUntil { chat.messages.first?.state == .sent }
        let clientId = try XCTUnwrap(StubURLProtocol.lastClientId)

        let row = "{\"id\":\"server-1\",\"sender\":\"user\",\"body\":\"Hi\",\"client_id\":\""
            + clientId
            + "\",\"sent_at\":\"2026-09-23T10:00:00.000000+00:00\",\"read_at\":null}"
        StubURLProtocol.respond(status: 200, body: "{\"messages\":[" + row + "],\"unread\":0}")
        chat.refresh()

        try await waitUntil { chat.messages.first?.id == "server-1" }
        XCTAssertEqual(chat.messages.count, 1, "the same message must not appear twice")
        XCTAssertEqual(chat.messages.map(\.body), ["Hi"])
    }

    /// The other half: two messages that genuinely say the same thing are two
    /// messages, so matching on the text would be wrong.
    func testRepeatedTextStaysTwoMessages() async throws {
        StubURLProtocol.respond(status: 200, body: "{}")
        let chat = Chat()

        chat.send("Hi")
        try await waitUntil { chat.messages.count == 1 }
        chat.send("Hi")

        try await waitUntil { chat.messages.count == 2 }
        XCTAssertEqual(chat.messages.map(\.body), ["Hi", "Hi"])
    }

    /// Every request proves it owns the conversation. Without this the server
    /// is back to trusting a device id, which is not a secret.
    func testRequestsCarryTheInstallSecret() async throws {
        StubURLProtocol.respond(status: 200, body: "{}")
        let chat = Chat()

        chat.send("is anyone there?")

        try await waitUntil { StubURLProtocol.lastAuthorization != nil }
        let header = try XCTUnwrap(StubURLProtocol.lastAuthorization)
        let secret = header.replacingOccurrences(of: "Bearer ", with: "")
        XCTAssertTrue(header.hasPrefix("Bearer "))
        XCTAssertEqual(secret.count, 43, "32 random bytes, base64url, unpadded")
        XCTAssertNil(
            secret.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")),
            "the secret must survive a header untouched"
        )
    }

    /// The same install keeps the same secret, or it would lose its history on
    /// every launch — and a refresh must not name the device in the URL, where
    /// it would end up in logs.
    func testSecretIsStableAndDeviceIdIsNotInTheQuery() async throws {
        StubURLProtocol.respond(status: 200, body: #"{"messages":[],"unread":0}"#)
        let first = Chat()
        first.refresh()
        try await waitUntil { StubURLProtocol.lastAuthorization != nil }
        let firstSecret = try XCTUnwrap(StubURLProtocol.lastAuthorization)
        let url = try XCTUnwrap(StubURLProtocol.lastURL)

        XCTAssertFalse(
            url.absoluteString.contains("device_id"),
            "a refresh is authenticated by the secret, not by naming the device"
        )

        let second = Chat()
        second.refresh()
        try await waitUntil { StubURLProtocol.requestCount >= 2 }
        XCTAssertEqual(StubURLProtocol.lastAuthorization, firstSecret)
    }

    /// A reply that lands while the conversation is open is not announced —
    /// the presenter asks this, so it has to survive the screen coming and
    /// going rather than latching on first appearance.
    func testScreenVisibilityDrivesNotificationSuppression() async throws {
        let chat = Chat()
        XCTAssertFalse(chat.isOnScreen, "a chat nobody opened announces replies")

        chat.screenAppeared()
        XCTAssertTrue(chat.isOnScreen)

        chat.screenDisappeared()
        XCTAssertFalse(chat.isOnScreen, "a closed screen must let banners through again")
    }

    /// The message is in the notification, so it should be on screen before
    /// any fetch returns — and the fetch must then recognise it rather than
    /// showing it twice.
    func testNotificationShowsItsMessageBeforeTheFetchLands() async throws {
        StubURLProtocol.failWithNetworkError()
        let chat = Chat()

        chat.notificationArrived(
            messageId: "server-99",
            body: "we pushed a fix, try again"
        )

        XCTAssertEqual(chat.messages.count, 1, "the pushed message must not wait for the network")
        XCTAssertEqual(chat.messages.first?.body, "we pushed a fix, try again")
        XCTAssertEqual(chat.messages.first?.sender, .owner)

        // The same message, as the server stores it.
        StubURLProtocol.respond(
            status: 200,
            body: #"{"messages":[{"id":"server-99","sender":"owner","body":"we pushed a fix, try again","client_id":null,"sent_at":"2026-09-20T10:00:00.000000+00:00","read_at":null}],"unread":1}"#
        )
        // Polled the way the open screen polls: a refresh already in flight
        // makes the next one a no-op, which is the SDK behaving correctly.
        // Polled the way the open screen polls: a refresh already in flight
        // makes the next one a no-op, which is the SDK behaving correctly.
        // The stored copy carries the server's timestamp, so seeing that
        // timestamp is what proves the two were reconciled rather than both
        // kept.
        let stored = ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z")!
        try await waitUntil {
            chat.refresh()
            guard let sentAt = chat.messages.first?.sentAt else { return false }
            return abs(sentAt.timeIntervalSince(stored)) < 1
        }
        XCTAssertEqual(chat.messages.count, 1, "the notification copy and the stored one are one message")
    }

    /// The dashboard owns who answers; the app only supplies a fallback and
    /// how it looks. Two places to change a name is one too many.
    func testResponderNameFollowsTheServer() async throws {
        StubURLProtocol.respond(
            status: 200,
            body: #"{"messages":[],"unread":0,"responder":{"name":"Sahil","role":"Founder"}}"#
        )
        let chat = Chat()
        let fallback = ChatResponder(name: "Support", avatar: .cartoon, isOnline: true)

        XCTAssertEqual(
            chat.resolvedResponder(fallback: fallback)?.name,
            "Support",
            "before the fetch, the app's own fallback stands"
        )

        chat.refresh()

        try await waitUntil { chat.responderName == "Sahil" }
        let resolved = try XCTUnwrap(chat.resolvedResponder(fallback: fallback))
        XCTAssertEqual(resolved.name, "Sahil")
        XCTAssertEqual(resolved.role, "Founder")
        XCTAssertEqual(resolved.avatar, .cartoon, "how it looks stays the app's business")
        XCTAssertTrue(resolved.isOnline)
    }

    /// An app that has named nobody must not blank out the name the app
    /// shipped with.
    func testEmptyServerResponderKeepsTheFallback() async throws {
        StubURLProtocol.respond(status: 200, body: #"{"messages":[],"unread":0,"responder":null}"#)
        let chat = Chat()
        chat.refresh()

        try await waitUntil { StubURLProtocol.requestCount >= 1 }
        XCTAssertNil(chat.responderName)
        XCTAssertEqual(
            chat.resolvedResponder(fallback: ChatResponder(name: "Support"))?.name,
            "Support"
        )
    }

    /// A conversation longer than a page opens on the newest one and can walk
    /// backwards — the older page goes in front of what is already held, in
    /// time order.
    func testOlderMessagesArePrependedInOrder() async throws {
        StubURLProtocol.respond(
            status: 200,
            body: #"""
            {"messages":[
              {"id":"m3","sender":"user","body":"third","client_id":null,"sent_at":"2026-09-20T12:00:00.000000+00:00","read_at":null}
            ],"unread":0,"has_more":true}
            """#
        )
        let chat = Chat()
        chat.refresh()
        try await waitUntil { chat.messages.count == 1 }
        XCTAssertTrue(chat.hasMoreHistory, "a full page means something sits above it")

        StubURLProtocol.respond(
            status: 200,
            body: #"""
            {"messages":[
              {"id":"m1","sender":"user","body":"first","client_id":null,"sent_at":"2026-09-20T10:00:00.000000+00:00","read_at":null},
              {"id":"m2","sender":"owner","body":"second","client_id":null,"sent_at":"2026-09-20T11:00:00.000000+00:00","read_at":null}
            ],"has_more":false}
            """#
        )
        chat.loadOlderMessages()

        try await waitUntil { chat.messages.count == 3 }
        XCTAssertEqual(chat.messages.map(\.body), ["first", "second", "third"])
        XCTAssertFalse(chat.hasMoreHistory, "the start of the conversation stops the asking")
    }

    /// Reaching the start is remembered: the newest page cannot report it, and
    /// a poll saying "there is more above me" must not undo it.
    func testReachingTheStartSurvivesAPoll() async throws {
        StubURLProtocol.respond(
            status: 200,
            body: #"{"messages":[{"id":"m2","sender":"user","body":"second","client_id":null,"sent_at":"2026-09-20T11:00:00.000000+00:00","read_at":null}],"unread":0,"has_more":true}"#
        )
        let chat = Chat()
        chat.refresh()
        try await waitUntil { chat.hasMoreHistory }

        StubURLProtocol.respond(
            status: 200,
            body: #"{"messages":[{"id":"m1","sender":"user","body":"first","client_id":null,"sent_at":"2026-09-20T10:00:00.000000+00:00","read_at":null}],"has_more":false}"#
        )
        chat.loadOlderMessages()
        try await waitUntil { chat.messages.count == 2 && !chat.hasMoreHistory }

        // A later poll of the newest page still reports more above itself.
        StubURLProtocol.respond(
            status: 200,
            body: #"{"messages":[],"unread":0,"has_more":true}"#
        )
        try await waitUntil {
            chat.refresh()
            return StubURLProtocol.requestCount >= 3
        }
        XCTAssertFalse(chat.hasMoreHistory, "history already walked to its start stays walked")
    }

    /// The install says hello so the owner can start a conversation with
    /// someone who has never written — and says it with the key it holds, so
    /// the server learns a hash rather than being asked to invent one.
    func testRefreshIntroducesTheInstall() async throws {
        StubURLProtocol.respond(status: 200, body: #"{"messages":[],"unread":0}"#)
        let chat = Chat()

        chat.refresh()

        try await waitUntil { StubURLProtocol.registeredPaths.contains("/api/chat/register") }
        let header = try XCTUnwrap(StubURLProtocol.lastAuthorization)
        XCTAssertTrue(header.hasPrefix("Bearer "), "registration carries the key, not the device id alone")
    }

    /// A first launch with no connection must not spend the introduction: the
    /// install would stay unreachable until the next cold start, and the owner
    /// would be told it had never run a chat-capable build.
    func testRegistrationIsRetriedAfterAFailedAttempt() async throws {
        StubURLProtocol.failWithNetworkError()
        let chat = Chat()

        chat.refresh()
        try await waitUntil { StubURLProtocol.requestCount >= 1 }
        try await waitUntil { !Chat.hasRegisteredThisLaunch }

        StubURLProtocol.respond(status: 200, body: #"{"ok":true,"registered":true}"#)
        try await waitUntil {
            chat.refresh()
            return Chat.hasRegisteredThisLaunch
        }
        XCTAssertTrue(
            StubURLProtocol.registeredPaths.contains("/api/chat/register"),
            "the install says hello again once there is a network to say it on"
        )
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private var queueURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("astronaut-chat-queue.json")
    }

    private func queueFileExists() -> Bool {
        guard let url = queueURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The session key outlives a test the way it outlives a launch — which is
    /// the point of it, and why one test adopting a key would otherwise decide
    /// what every later test sees.
    private func removeStoredSecret() {
        UserDefaults.standard.removeObject(forKey: "astronaut_chat_key_naut_test")
    }

    private func removeQueueFile() {
        guard let url = queueURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Answers every request the SDK makes, so the tests never touch a network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = "{}"
    nonisolated(unsafe) private static var shouldFail = false
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var clientId: String?
    nonisolated(unsafe) private static var authorization: String?
    nonisolated(unsafe) private static var url: URL?
    nonisolated(unsafe) private static var paths: Set<String> = []

    /// Every path asked for so far, so a test can check that something was
    /// announced as well as what came back.
    static var registeredPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    /// The Authorization header of the last request, so the tests can check
    /// that the install actually authenticates itself.
    static var lastAuthorization: String? {
        lock.lock(); defer { lock.unlock() }
        return authorization
    }

    static var lastURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return url
    }

    /// The client_id of the last message sent, so a refresh can be answered
    /// with the row the server would have stored for it.
    static var lastClientId: String? {
        lock.lock(); defer { lock.unlock() }
        return clientId
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func respond(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.body = body
        shouldFail = false
    }

    static func failWithNetworkError() {
        lock.lock(); defer { lock.unlock() }
        shouldFail = true
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        status = 200
        body = "{}"
        shouldFail = false
        count = 0
        clientId = nil
        authorization = nil
        url = nil
        paths = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves a request body into a stream, so httpBody is nil by
        // the time a protocol sees it.
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            bodyData = collected
        }

        Self.lock.lock()
        Self.count += 1
        Self.authorization = request.value(forHTTPHeaderField: "Authorization")
        Self.url = request.url
        if let path = request.url?.path { Self.paths.insert(path) }
        if let bodyData,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let sent = json["client_id"] as? String {
            Self.clientId = sent
        }
        let failing = Self.shouldFail
        let status = Self.status
        let body = Self.body
        Self.lock.unlock()

        if failing {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
