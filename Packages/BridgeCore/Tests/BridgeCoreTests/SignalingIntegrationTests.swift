import Foundation
import Testing
@testable import BridgeCore

/// Runs the real signaling server (`server/`) and talks to it with the real
/// client, so the Swift and TypeScript sides cannot drift apart.
/// Skipped when Node or the server's dependencies are not installed.
@Suite(.serialized, .enabled(if: LocalServer.isAvailable, "needs node and server/node_modules"))
struct SignalingIntegrationTests {
    @Test(.timeLimit(.minutes(1)))
    func relaysSignalsAndReportsOfflinePeers() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }

        let studioID = Identity(), laptopID = Identity()
        let studio = SignalingClient(url: server.url, identity: studioID, accessToken: LocalServer.token)
        let laptop = SignalingClient(url: server.url, identity: laptopID, accessToken: LocalServer.token)
        defer { studio.disconnect(); laptop.disconnect() }

        let studioInbox = Inbox(), laptopInbox = Inbox()
        studioInbox.attach(to: studio)
        laptopInbox.attach(to: laptop)
        studio.connect()
        laptop.connect()
        try await poll("both devices online") { studioInbox.status == .online && laptopInbox.status == .online }

        let auth = SessionAuth.sign(.request, to: studioID.deviceID, identity: laptopID)
        laptop.send(SignalEnvelope(.request, auth: auth), to: studioID.deviceID)
        try await poll("request reaches studio") { studioInbox.signals.count == 1 }
        #expect(studioInbox.signals.first?.from == laptopID.deviceID)
        // The proof survives the trip through the server intact.
        #expect(studioInbox.signals.first?.envelope == SignalEnvelope(.request, auth: auth))

        let candidate = SignalPayload.candidate(sdp: "candidate:1 1 udp 1 10.0.0.1 5000 typ host", mLineIndex: 0, mid: "0")
        studio.send(SignalEnvelope(.offer(sdp: "v=0\r\n")), to: laptopID.deviceID)
        studio.send(SignalEnvelope(candidate), to: laptopID.deviceID)
        try await poll("offer and candidate reach laptop") { laptopInbox.signals.count == 2 }
        #expect(laptopInbox.signals.map(\.envelope.payload) == [.offer(sdp: "v=0\r\n"), candidate])
        #expect(laptopInbox.signals.allSatisfy { $0.from == studioID.deviceID })

        laptop.send(SignalEnvelope(.request), to: "aaaaaaaaaaaaaaaa")
        try await poll("offline error") { laptopInbox.errors == [.peerOffline("aaaaaaaaaaaaaaaa")] }

        // No STUN/TURN is configured on the test server, so the answer is an empty list.
        laptop.requestIceServers { servers in laptopInbox.record(iceServers: servers) }
        try await poll("ice servers") { laptopInbox.iceServers == [] }
    }

    @Test(.timeLimit(.minutes(1)))
    func stopsRetryingWhenTheTokenIsWrong() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let client = SignalingClient(url: server.url, identity: Identity(), accessToken: "not-the-token")
        defer { client.disconnect() }
        let inbox = Inbox()
        inbox.attach(to: client)
        client.connect()
        try await poll("refusal") { inbox.errors == [.unauthorized("bad-token")] }
        try await poll("gives up") { inbox.status == .offline }
    }

    @Test(.timeLimit(.minutes(1)))
    func reconnectsAfterTheServerRestarts() async throws {
        var server = try await LocalServer.start()
        let client = SignalingClient(url: server.url, identity: Identity(), accessToken: LocalServer.token)
        defer { client.disconnect() }
        let inbox = Inbox()
        inbox.attach(to: client)
        client.connect()
        try await poll("online") { inbox.status == .online }

        server.stop()
        try await poll("notices the drop") { inbox.status == .connecting }

        server = try await LocalServer.start(port: server.port)
        defer { server.stop() }
        try await poll("back online") { inbox.status == .online }
    }

    @Test(.timeLimit(.minutes(1)))
    func anUnansweredPingCountsAsADrop() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let client = SignalingClient(url: server.url, identity: Identity(), accessToken: LocalServer.token)
        client.pingInterval = 0.2
        client.pingTimeout = 0.5
        defer { client.disconnect() }
        let inbox = Inbox()
        inbox.attach(to: client)
        client.connect()
        try await poll("online") { inbox.status == .online }
        try await Task.sleep(for: .seconds(1))
        #expect(inbox.status == .online) // answered pings keep it online

        // A frozen server keeps the socket open but answers nothing, like a dead network.
        server.process.suspend()
        try await poll("notices the silence") { inbox.status == .connecting }
        server.process.resume()
        try await poll("back online") { inbox.status == .online }
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondCopyWithTheSameKeyStopsTheFirst() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let identity = Identity()
        let first = SignalingClient(url: server.url, identity: identity, accessToken: LocalServer.token)
        let second = SignalingClient(url: server.url, identity: identity, accessToken: LocalServer.token)
        defer { first.disconnect(); second.disconnect() }
        let firstInbox = Inbox(), secondInbox = Inbox()
        firstInbox.attach(to: first)
        secondInbox.attach(to: second)
        first.connect()
        try await poll("first online") { firstInbox.status == .online }
        second.connect()
        try await poll("second online") { secondInbox.status == .online }
        // Both were just online, so each takes the first push-off for its own late login and
        // comes back once. The second push-off settles it: the first stays off.
        try await poll("first told") { firstInbox.errors == [.replaced] }
        try await poll("first gives up") { firstInbox.status == .offline }
        try await poll("second back") { secondInbox.status == .online }
        // No tug of war: the first stays off and the second stays on.
        try await Task.sleep(for: .seconds(2))
        #expect(firstInbox.status == .offline)
        #expect(secondInbox.status == .online)
        #expect(secondInbox.errors.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func presenceAsksInBatchesAndKeepsEachAnswerWithItsRequest() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let asker = SignalingClient(url: server.url, identity: Identity(), accessToken: LocalServer.token)
        let otherID = Identity()
        let other = SignalingClient(url: server.url, identity: otherID, accessToken: LocalServer.token)
        defer { asker.disconnect(); other.disconnect() }
        let askerInbox = Inbox(), otherInbox = Inbox()
        askerInbox.attach(to: asker)
        otherInbox.attach(to: other)
        asker.connect(); other.connect()
        try await poll("both online") { askerInbox.status == .online && otherInbox.status == .online }

        // More IDs than the server takes in one request, the online one in the second batch.
        var ids = (0..<150).map { _ in Identity().deviceID }
        ids[100] = otherID.deviceID
        let many = Answers()
        asker.presence(of: ids) { many.record($0) }
        try await poll("batched answer") { many.values.count == 1 }
        #expect(many.values == [[otherID.deviceID]])
        #expect(askerInbox.status == .online) // the server took every batch

        // A request that times out does not take the waiter of the one before it.
        let patient = Answers(), hasty = Answers()
        asker.presence(of: [otherID.deviceID]) { patient.record($0) }
        asker.presence(of: [otherID.deviceID], timeout: 0) { hasty.record($0) }
        try await poll("both done") { patient.values.count == 1 && hasty.values.count == 1 }
        #expect(hasty.values == [nil])
        #expect(patient.values == [[otherID.deviceID]])

        // Later requests still get their own answers.
        let later = Answers()
        asker.presence(of: [ids[0]]) { later.record($0) }
        try await poll("later answer") { later.values.count == 1 }
        #expect(later.values == [[]])
    }

    @Test func aReplacedCloseIsAnotherCopyOnlyWhenItCannotBeOurOwn() {
        // A settled connection pushed off: another copy.
        #expect(SignalingClient.isReplaced(onlineFor: 60, abandonedLoginFor: nil, excusedBefore: 0))
        // Just logged in, or not even welcomed: maybe our own older login finishing late.
        #expect(!SignalingClient.isReplaced(onlineFor: 1, abandonedLoginFor: nil, excusedBefore: 0))
        #expect(!SignalingClient.isReplaced(onlineFor: nil, abandonedLoginFor: nil, excusedBefore: 0))
        // A login dropped halfway a moment ago: the server may finish it after the new one.
        #expect(!SignalingClient.isReplaced(onlineFor: 60, abandonedLoginFor: 10, excusedBefore: 0))
        #expect(SignalingClient.isReplaced(onlineFor: 60, abandonedLoginFor: 45, excusedBefore: 0))
        // A second one in a row is never excused.
        #expect(SignalingClient.isReplaced(onlineFor: 1, abandonedLoginFor: 10, excusedBefore: 1))
    }

    @Test(.timeLimit(.minutes(1)))
    func checkingTheConnectionOftenKeepsOnePingChain() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let client = SignalingClient(url: server.url, identity: Identity(), accessToken: LocalServer.token)
        client.pingInterval = 0.3
        let pings = Answers()
        client.onPing = { pings.record(nil) }
        defer { client.disconnect() }
        let inbox = Inbox()
        inbox.attach(to: client)
        client.connect()
        try await poll("online") { inbox.status == .online }
        // Each wake or return to the front checks the connection with a ping of its own.
        for _ in 0..<8 {
            client.reconnectIfStale()
            try await Task.sleep(for: .milliseconds(60))
        }
        let before = pings.values.count
        try await Task.sleep(for: .seconds(1.5))
        let during = pings.values.count - before
        // One chain pings about 5 times in 1.5 s; a chain per check would be about 40.
        #expect(during <= 7)
        #expect(during >= 3)
        #expect(inbox.status == .online)
    }

    @Test func aByeReasonTravelsAndAnUnknownOneIsIgnored() throws {
        let envelope = SignalEnvelope(.bye, reason: .stale)
        let data = try JSONEncoder().encode(envelope)
        #expect(try JSONDecoder().decode(SignalEnvelope.self, from: data) == envelope)
        let newer = Data(#"{"kind":"bye","reason":"something-new"}"#.utf8)
        #expect(try JSONDecoder().decode(SignalEnvelope.self, from: newer) == SignalEnvelope(.bye))
        let older = Data(#"{"kind":"bye"}"#.utf8)
        #expect(try JSONDecoder().decode(SignalEnvelope.self, from: older) == SignalEnvelope(.bye))
    }
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Set<String>?] = []
    var values: [Set<String>?] { lock.withLock { _values } }
    func record(_ value: Set<String>?) { lock.withLock { _values.append(value) } }
}

private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var _status = SignalingClient.Status.offline
    private var _signals: [(from: String, envelope: SignalEnvelope)] = []
    private var _errors: [SignalingClient.ServerError] = []

    var status: SignalingClient.Status { lock.withLock { _status } }
    var signals: [(from: String, envelope: SignalEnvelope)] { lock.withLock { _signals } }
    var errors: [SignalingClient.ServerError] { lock.withLock { _errors } }
    private var _iceServers: [IceServer]?
    var iceServers: [IceServer]? { lock.withLock { _iceServers } }
    func record(iceServers: [IceServer]) { lock.withLock { _iceServers = iceServers } }

    func attach(to client: SignalingClient) {
        client.onStatus = { status in self.lock.withLock { self._status = status } }
        client.onSignal = { from, envelope in self.lock.withLock { self._signals.append((from, envelope)) } }
        client.onError = { error in self.lock.withLock { self._errors.append(error) } }
    }
}

struct LocalServer {
    let process: Process
    let port: Int
    var url: URL { URL(string: "ws://127.0.0.1:\(port)")! }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("server")

    static let token = "integration-test-token-0123456789"

    static let node: String? = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        .first(where: FileManager.default.isExecutableFile(atPath:))

    static var isAvailable: Bool {
        node != nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent("node_modules/ws").path)
    }

    /// Without a port, a random one; tried again on another if the server does not come up there.
    static func start(port: Int? = nil) async throws -> LocalServer {
        if let port { return try await launch(port: port) }
        for _ in 1..<3 {
            if let server = try? await launch(port: Int.random(in: 20_000...40_000)) { return server }
        }
        return try await launch(port: Int.random(in: 20_000...40_000))
    }

    private static func launch(port: Int) async throws -> LocalServer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(node))
        process.arguments = ["src/main.ts"]
        process.currentDirectoryURL = directory
        process.environment = ["PORT": "\(port)", "HOST": "127.0.0.1", "PATH": "/usr/bin:/bin", "ACCESS_TOKEN": token]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The server prints one line once it is listening.
        let ready = Task.detached { output.fileHandleForReading.availableData.isEmpty == false }
        guard await ready.value, process.isRunning else {
            process.terminate()
            throw CocoaError(.fileReadUnknown)
        }
        return LocalServer(process: process, port: port)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}

func poll(_ what: String, timeout: Duration = .seconds(15), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("timed out waiting for \(what)")
    throw CancellationError()
}
