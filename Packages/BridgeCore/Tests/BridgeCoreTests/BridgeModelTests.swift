import Foundation
import Testing
@testable import BridgeCore

/// Two app models talking through the real signaling server.
@Suite(.serialized, .enabled(if: LocalServer.isAvailable, "needs node and server/node_modules"))
@MainActor
struct BridgeModelTests {
    /// A model with its own settings and key, as if on a separate Mac.
    private func makeModel(_ name: String, server: LocalServer, token: String = LocalServer.token) -> BridgeModel {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory(token))
        model.serverURL = server.url.absoluteString
        model.deviceName = name
        return model
    }

    private func shownCode(_ model: BridgeModel) -> String? {
        if case let .showingCode(code, _) = model.pairingStatus { return code }
        return nil
    }

    @Test(.timeLimit(.minutes(1)))
    func pairingGivesControlInOneDirectionOnly() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server), laptop = makeModel("Laptop", server: server)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.goOnline(); laptop.goOnline()
        try await poll("both online") { studio.signalingStatus == .online && laptop.signalingStatus == .online }

        studio.showPairingCode()
        let code = try #require(shownCode(studio))
        // Give the server a moment to register the code before it is typed.
        try await Task.sleep(for: .milliseconds(200))
        laptop.pair(usingCode: code.lowercased())

        try await poll("both sides paired") { studio.paired.count == 1 && laptop.paired.count == 1 }

        // Studio showed the code: Laptop may control Studio, not the reverse.
        let laptopAtStudio = try #require(studio.paired.first)
        #expect(laptopAtStudio.id == laptop.deviceID)
        #expect(laptopAtStudio.publicKey == laptop.identity.publicKey)
        #expect(laptopAtStudio.name == "Laptop")
        #expect(laptopAtStudio.mayControlThisMac && !laptopAtStudio.thisMacMayControl)

        let studioAtLaptop = try #require(laptop.paired.first)
        #expect(studioAtLaptop.id == studio.deviceID)
        #expect(studioAtLaptop.publicKey == studio.identity.publicKey)
        #expect(studioAtLaptop.thisMacMayControl && !studioAtLaptop.mayControlThisMac)

        #expect(laptop.controllable.map(\.id) == [studio.deviceID])
        #expect(studio.controllable.isEmpty)
        #expect(studio.pairingStatus == .idle && laptop.pairingStatus == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCodeWorksOnlyOnce() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server)
        let laptop = makeModel("Laptop", server: server), intruder = makeModel("Intruder", server: server)
        defer { studio.goOffline(); laptop.goOffline(); intruder.goOffline() }
        [studio, laptop, intruder].forEach { $0.goOnline() }
        try await poll("all online") { [studio, laptop, intruder].allSatisfy { $0.signalingStatus == .online } }

        studio.showPairingCode()
        let code = try #require(shownCode(studio))
        try await Task.sleep(for: .milliseconds(200))
        laptop.pair(usingCode: code)
        try await poll("laptop paired") { laptop.paired.count == 1 }

        intruder.pair(usingCode: code)
        try await poll("second use refused") {
            if case .failed = intruder.pairingStatus { return true }
            return false
        }
        #expect(intruder.paired.isEmpty)
        #expect(studio.paired.map(\.id) == [laptop.deviceID])
    }

    @Test(.timeLimit(.minutes(1)))
    func aWrongCodePairsNothing() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server), laptop = makeModel("Laptop", server: server)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.goOnline(); laptop.goOnline()
        try await poll("both online") { studio.signalingStatus == .online && laptop.signalingStatus == .online }

        studio.showPairingCode()
        try await Task.sleep(for: .milliseconds(200))
        laptop.pair(usingCode: PairingCode().display)
        try await poll("refused") {
            if case .failed = laptop.pairingStatus { return true }
            return false
        }
        laptop.pair(usingCode: "nonsense")
        #expect(laptop.pairingStatus == .failed("That is not a valid code. It has 16 letters and digits."))
        #expect(studio.paired.isEmpty && laptop.paired.isEmpty)
        #expect(shownCode(studio) != nil) // the real code is still usable
    }

    @Test(.timeLimit(.minutes(1)))
    func anUnpairedDeviceCannotStartASession() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server)
        defer { studio.goOffline() }
        studio.allowsControl = true
        studio.goOnline()
        try await poll("studio online") { studio.signalingStatus == .online }

        // A device with the server token but no pairing sends a correctly signed request.
        let stranger = Identity()
        let client = SignalingClient(url: server.url, identity: stranger, accessToken: LocalServer.token)
        defer { client.disconnect() }
        var online = false, replies = 0
        client.onStatus = { online = $0 == .online }
        client.onSignal = { _, _ in replies += 1 }
        client.connect()
        try await poll("stranger online") { online }
        client.send(SignalEnvelope(.request, auth: SessionAuth.sign(.request, to: studio.deviceID, identity: stranger)),
                    to: studio.deviceID)

        try await Task.sleep(for: .seconds(1))
        #expect(studio.hostStatus == .idle)
        #expect(studio.notice == nil)
        #expect(replies == 0) // not even a refusal: the host does not answer strangers
    }

    @Test(.timeLimit(.minutes(1)))
    func revokingRemovesTheRightToControl() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server), laptop = makeModel("Laptop", server: server)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.goOnline(); laptop.goOnline()
        try await poll("both online") { studio.signalingStatus == .online && laptop.signalingStatus == .online }
        studio.showPairingCode()
        let code = try #require(shownCode(studio))
        try await Task.sleep(for: .milliseconds(200))
        laptop.pair(usingCode: code)
        try await poll("paired") { studio.paired.count == 1 && laptop.paired.count == 1 }

        studio.revokeControl(from: try #require(studio.controllers.first))
        #expect(studio.paired.isEmpty)

        // Laptop still thinks it is paired and tries to connect; Studio stays silent.
        studio.allowsControl = true
        laptop.connect(to: try #require(laptop.controllable.first))
        try await Task.sleep(for: .seconds(1))
        #expect(studio.hostStatus == .idle)
        #expect(laptop.remoteVideo == nil)
    }

    @Test func pairedDevicesSurviveARestart() throws {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = PairedDevice(id: "abcdefghijklmnop", publicKey: Data(repeating: 7, count: 32), name: "Studio",
                                  thisMacMayControl: true)
        defaults.set(try JSONEncoder().encode([device]), forKey: "pairedDevices")

        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory())
        #expect(model.paired == [device])
        model.forget(device)
        #expect(BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory()).paired.isEmpty)
    }

    @Test func namesFromOtherDevicesAreMadeSafeToShow() {
        #expect(BridgeModel.label("  Studio\n", id: "abcdefgh") == "Studio")
        #expect(BridgeModel.label("", id: "abcdefgh") == "Mac abcd")
        #expect(BridgeModel.label("a\u{07}b\u{1B}c", id: "abcdefgh") == "abc")
        #expect(BridgeModel.label(String(repeating: "x", count: 500), id: "abcdefgh").count == 64)
    }
}
