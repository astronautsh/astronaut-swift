import XCTest
@testable import Astronaut

/// Tests for the part of support chat that cannot be checked by eye: what
/// happens to a message when the network is against it. The queue is the
/// reason chat can promise delivery at all, so its behaviour is pinned here.
@MainActor
final class SupportChatTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        Astronaut.shared.configure(AstronautConfiguration(trackingId: "naut_test"))
        removeQueueFile()
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        removeQueueFile()
        try await super.tearDown()
    }

    /// The message appears straight away, marked as on its way, and is on disk
    /// before the request is even attempted — a send must survive the app
    /// being closed a second later.
    func testSendShowsImmediatelyAndPersists() async throws {
        StubURLProtocol.respond(status: 200, body: #"{"message":{"id":"m1"}}"#)
        let chat = SupportChat()

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
        let chat = SupportChat()

        chat.send("x")

        try await waitUntil { chat.messages.first?.state == .failed }
        XCTAssertFalse(queueFileExists(), "a rejected message should not be retried forever")
    }

    /// A network blip keeps the message queued and still showing as sending,
    /// so the next launch can try again.
    func testNetworkFailureKeepsMessageQueued() async throws {
        StubURLProtocol.failWithNetworkError()
        let chat = SupportChat()

        chat.send("are you there?")

        try await waitUntil { StubURLProtocol.requestCount >= 1 }
        XCTAssertEqual(chat.messages.first?.state, .sending)
        XCTAssertTrue(queueFileExists(), "an unsent message must outlive the launch")
    }

    /// Rate limiting is temporary, so it is treated like a network failure
    /// rather than a rejection: the message stays and tries again later.
    func testRateLimitKeepsMessageQueued() async throws {
        StubURLProtocol.respond(status: 429, body: #"{"error":"Too many messages."}"#)
        let chat = SupportChat()

        chat.send("hello?")

        try await waitUntil { StubURLProtocol.requestCount >= 1 }
        XCTAssertEqual(chat.messages.first?.state, .sending)
        XCTAssertTrue(queueFileExists())
    }

    /// A message written on a previous launch is restored, still marked as
    /// sending, so nothing silently disappears between runs.
    func testQueueSurvivesRelaunch() async throws {
        StubURLProtocol.failWithNetworkError()
        let first = SupportChat()
        first.send("written before the crash")
        try await waitUntil { StubURLProtocol.requestCount >= 1 }

        StubURLProtocol.respond(status: 200, body: #"{"message":{"id":"m1"}}"#)
        let second = SupportChat()

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
        let chat = SupportChat()

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
            .appendingPathComponent("astronaut-support-queue.json")
    }

    private func queueFileExists() -> Bool {
        guard let url = queueURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
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
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
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
