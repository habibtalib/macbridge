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

    static func start(port: Int = Int.random(in: 20_000...40_000)) async throws -> LocalServer {
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
