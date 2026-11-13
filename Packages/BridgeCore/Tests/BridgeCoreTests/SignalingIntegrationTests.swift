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

        let studio = SignalingClient(url: server.url, deviceID: "studio")
        let laptop = SignalingClient(url: server.url, deviceID: "laptop")
        defer { studio.disconnect(); laptop.disconnect() }

        let studioInbox = Inbox(), laptopInbox = Inbox()
        studioInbox.attach(to: studio)
        laptopInbox.attach(to: laptop)
        studio.connect()
        laptop.connect()
        try await poll("both devices online") { studioInbox.status == .online && laptopInbox.status == .online }

        laptop.send(.request, to: "studio")
        try await poll("request reaches studio") { studioInbox.signals.count == 1 }
        #expect(studioInbox.signals.first?.from == "laptop")
        #expect(studioInbox.signals.first?.payload == .request)

        let candidate = SignalPayload.candidate(sdp: "candidate:1 1 udp 1 10.0.0.1 5000 typ host", mLineIndex: 0, mid: "0")
        studio.send(.offer(sdp: "v=0\r\n"), to: "laptop")
        studio.send(candidate, to: "laptop")
        try await poll("offer and candidate reach laptop") { laptopInbox.signals.count == 2 }
        #expect(laptopInbox.signals.map(\.payload) == [.offer(sdp: "v=0\r\n"), candidate])
        #expect(laptopInbox.signals.allSatisfy { $0.from == "studio" })

        laptop.send(.request, to: "nobody")
        try await poll("offline error") { laptopInbox.errors == [.peerOffline("nobody")] }
    }

    @Test(.timeLimit(.minutes(1)))
    func reconnectsAfterTheServerRestarts() async throws {
        var server = try await LocalServer.start()
        let client = SignalingClient(url: server.url, deviceID: "studio")
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
    private var _signals: [(from: String, payload: SignalPayload)] = []
    private var _errors: [SignalingClient.ServerError] = []

    var status: SignalingClient.Status { lock.withLock { _status } }
    var signals: [(from: String, payload: SignalPayload)] { lock.withLock { _signals } }
    var errors: [SignalingClient.ServerError] { lock.withLock { _errors } }

    func attach(to client: SignalingClient) {
        client.onStatus = { status in self.lock.withLock { self._status = status } }
        client.onSignal = { from, payload in self.lock.withLock { self._signals.append((from, payload)) } }
        client.onError = { error in self.lock.withLock { self._errors.append(error) } }
    }
}

private struct LocalServer {
    let process: Process
    let port: Int
    var url: URL { URL(string: "ws://127.0.0.1:\(port)")! }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("server")

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
        process.environment = ["PORT": "\(port)", "HOST": "127.0.0.1", "PATH": "/usr/bin:/bin"]
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

private func poll(_ what: String, timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("timed out waiting for \(what)")
    throw CancellationError()
}
