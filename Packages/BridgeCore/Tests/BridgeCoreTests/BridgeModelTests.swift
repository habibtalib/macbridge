import Foundation
import Testing
@testable import BridgeCore

/// Two app models talking through the real signaling server.
@Suite(.serialized, .enabled(if: LocalServer.isAvailable, "needs node and server/node_modules"))
@MainActor
struct BridgeModelTests {
    /// A model with its own settings and key, as if on a separate Mac.
    private func makeModel(_ name: String, server: LocalServer, token: String = LocalServer.token, local: Bool = false) -> BridgeModel {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory(token), usesLocalNetwork: local)
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

    /// Studio shows a code, Laptop types it: Laptop may control Studio.
    private func pairedModels(_ server: LocalServer, local: Bool = false) async throws -> (studio: BridgeModel, laptop: BridgeModel) {
        let studio = makeModel("Studio", server: server, local: local), laptop = makeModel("Laptop", server: server, local: local)
        studio.goOnline(); laptop.goOnline()
        try await poll("both online") { studio.signalingStatus == .online && laptop.signalingStatus == .online }
        studio.showPairingCode()
        let code = try #require(shownCode(studio))
        try await Task.sleep(for: .milliseconds(200))
        laptop.pair(usingCode: code)
        try await poll("paired") { studio.paired.count == 1 && laptop.paired.count == 1 }
        return (studio, laptop)
    }

    @Test(.timeLimit(.minutes(1)))
    func tilesShowWhichMacsAreOnline() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (studio, laptop) = try await pairedModels(server)
        defer { studio.goOffline(); laptop.goOffline() }

        #expect(laptop.presence.isEmpty) // unknown until asked
        laptop.refreshPresence()
        try await poll("studio shown online") { laptop.presence[studio.deviceID] == true }
        studio.goOffline()
        try await Task.sleep(for: .milliseconds(300))
        laptop.refreshPresence()
        try await poll("studio shown offline") { laptop.presence[studio.deviceID] == false }
        laptop.goOffline()
        laptop.refreshPresence()
        #expect(laptop.presence.isEmpty)
    }

    /// Paired over the server, then the server goes away (Tailscale off, server down): the two
    /// still find each other on this network and the call goes through. Opt-in, like the other
    /// Bonjour test: it advertises on the local network.
    @Test(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["MACBRIDGE_BONJOUR_TEST"] == "1"))
    func callsGoThroughOnTheLocalNetworkWithoutTheServer() async throws {
        let server = try await LocalServer.start()
        let (studio, laptop) = try await pairedModels(server, local: true)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.allowsControl = true
        studio.setAsksFirst(try #require(studio.controllers.first), true)
        server.stop()
        studio.goOnline(); laptop.goOnline()
        try await poll("found on the network") { laptop.nearby == [studio.deviceID] && studio.nearby == [laptop.deviceID] }
        #expect(laptop.signalingStatus != .online)
        #expect(laptop.presence[studio.deviceID] == true)
        #expect(studio.power.keepSystemAwake)

        let studioAtLaptop = try #require(laptop.controllable.first)
        #expect(laptop.canConnect(to: studioAtLaptop))
        laptop.connect(to: studioAtLaptop)
        try await poll("studio asks") { studio.pendingRequest?.peer.id == laptop.deviceID }
        studio.declineRequest()
        try await poll("laptop told") {
            if case let .failed(message) = laptop.controllerStatus { return message.contains("did not accept") }
            return false
        }

        // Going offline leaves the network too.
        studio.goOffline()
        try await poll("studio gone") { laptop.nearby.isEmpty && laptop.presence[studio.deviceID] != true }
    }

    /// Relay only, but the server offers no relay: the call fails at once with the reason,
    /// instead of a session that can never connect (a dark screen).
    @Test(.timeLimit(.minutes(1)))
    func relayOnlyWithoutARelayFailsWithTheReason() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (studio, laptop) = try await pairedModels(server)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.allowsControl = true
        laptop.forcesRelay = true
        laptop.connect(to: try #require(laptop.controllable.first))
        try await poll("failed with the reason") { laptop.controllerStatus == .failed(BridgeModel.noRelayMessage) }
        #expect(studio.hostStatus == .idle)
    }

    @Test func relayMeansTurn() {
        #expect(!BridgeModel.hasRelay([]))
        #expect(!BridgeModel.hasRelay([IceServer(urls: ["stun:turn.example.com:3478"])]))
        #expect(BridgeModel.hasRelay([IceServer(urls: ["stun:x:3478", "turn:x:3478?transport=udp"])]))
        #expect(BridgeModel.hasRelay([IceServer(urls: ["TURNS:x:5349"])]))
    }

    @Test(.timeLimit(.minutes(1)))
    func aMacSetToAskFirstWaitsForAnAnswer() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (studio, laptop) = try await pairedModels(server)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.allowsControl = true
        let laptopAtStudio = try #require(studio.controllers.first)
        let studioAtLaptop = try #require(laptop.controllable.first)
        studio.setAsksFirst(laptopAtStudio, true)

        // Declined by the person at Studio.
        laptop.connect(to: studioAtLaptop)
        try await poll("studio asks") { studio.pendingRequest?.peer.id == laptop.deviceID }
        #expect(studio.hostStatus == .idle)
        studio.declineRequest()
        #expect(studio.pendingRequest == nil)
        try await poll("laptop is told") { laptop.controllerStatus == .failed("Studio did not accept the connection") }
        #expect(laptop.lastHost == studioAtLaptop)

        // Nobody answers: declined by itself.
        studio.askTimeout = 0.5
        laptop.reconnect()
        try await poll("studio asks again") { studio.pendingRequest != nil }
        try await poll("times out") { studio.pendingRequest == nil }
        try await poll("laptop is told again") { laptop.controllerStatus == .failed("Studio did not accept the connection") }
        laptop.dismissFailure()
        #expect(laptop.controllerStatus == .idle)

        // The caller gives up while the question is showing.
        studio.askTimeout = 30
        laptop.connect(to: studioAtLaptop)
        try await poll("studio asks a third time") { studio.pendingRequest != nil }
        laptop.disconnect()
        try await poll("question goes away") { studio.pendingRequest == nil }

        // Turning control off answers no.
        laptop.connect(to: studioAtLaptop)
        try await poll("studio asks a fourth time") { studio.pendingRequest != nil }
        studio.allowsControl = false
        #expect(studio.pendingRequest == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func revokingAnswersAQuestionStillShowing() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (studio, laptop) = try await pairedModels(server)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.allowsControl = true
        let laptopAtStudio = try #require(studio.controllers.first)
        studio.setAsksFirst(laptopAtStudio, true)

        laptop.connect(to: try #require(laptop.controllable.first))
        try await poll("studio asks") { studio.pendingRequest?.peer.id == laptop.deviceID }
        studio.revokeControl(from: laptopAtStudio)
        #expect(studio.pendingRequest == nil)
        studio.acceptRequest() // too late: nothing is waiting
        try await poll("laptop is told") { laptop.controllerStatus == .failed("Studio did not accept the connection") }
        #expect(studio.hostStatus == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func acceptingAfterRevokingDoesNotLetTheMacIn() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (studio, laptop) = try await pairedModels(server)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.allowsControl = true
        let laptopAtStudio = try #require(studio.controllers.first)
        studio.setAsksFirst(laptopAtStudio, true)

        laptop.connect(to: try #require(laptop.controllable.first))
        try await poll("studio asks") { studio.pendingRequest?.peer.id == laptop.deviceID }
        // Accepted, then revoked before the session starts: the session must look the right up again.
        studio.acceptRequest()
        studio.revokeControl(from: laptopAtStudio)
        try await poll("laptop is told") { laptop.controllerStatus == .failed(BridgeModel.refusal(.notAllowed, from: "Studio")) }
        #expect(studio.hostStatus == .idle)
        #expect(studio.notice?.contains("tried to connect") != true) // turned away before any permission check
    }

    /// Laptop may control Studio; Studio's model goes offline and a bare client with Studio's key
    /// stands in for it, to answer exactly as a test needs.
    private func laptopCallingAStandIn(_ server: LocalServer) async throws
        -> (laptop: BridgeModel, studioID: Identity, standIn: SignalingClient, received: Received)
    {
        let (studio, laptop) = try await pairedModels(server)
        studio.goOffline()
        let standIn = SignalingClient(url: server.url, identity: studio.identity, accessToken: LocalServer.token)
        let received = Received()
        standIn.onStatus = { received.online = $0 == .online }
        standIn.onSignal = { _, envelope in received.payloads.append(envelope.payload) }
        standIn.connect()
        try await poll("stand-in online") { received.online }
        return (laptop, studio.identity, standIn, received)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallNobodyAnswersFails() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (laptop, _, standIn, received) = try await laptopCallingAStandIn(server)
        defer { laptop.goOffline(); standIn.disconnect() }
        laptop.callTimeout = 0.5
        let studio = try #require(laptop.controllable.first)
        laptop.connect(to: studio)
        try await poll("request arrives") { received.payloads == [.request] }
        try await poll("gives up") { laptop.controllerStatus == .failed("No answer from Studio. Check that it is awake, online and allows control.") }
        try await poll("host told") { received.payloads == [.request, .bye] }
    }

    @Test(.timeLimit(.minutes(1)))
    func theSavedQualityIsAskedForOnceTheChannelsOpen() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (laptop, studioID, standIn, received) = try await laptopCallingAStandIn(server)
        defer { laptop.goOffline(); standIn.disconnect() }
        laptop.preferredQuality = .light
        let studio = try #require(laptop.controllable.first)

        // The stand-in answers as a host would: a host session wired through the server.
        let host = try #require(PeerSession(role: .host))
        defer { host.close() }
        let laptopID = laptop.deviceID
        host.onSignal = { payload in
            standIn.send(SignalEnvelope(payload, auth: SessionAuth.sign(payload, to: laptopID, identity: studioID)), to: laptopID)
        }
        host.onInput = { message in DispatchQueue.main.async { received.input.append(message) } }
        standIn.onSignal = { _, envelope in
            received.payloads.append(envelope.payload)
            switch envelope.payload {
            case .request: host.start()
            case .answer, .candidate: host.handle(envelope.payload)
            default: break
            }
        }

        laptop.connect(to: studio)
        try await poll("quality asked for") { received.input.contains(.quality(.light)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(received.input.filter { if case .quality = $0 { true } else { false } } == [.quality(.light)])
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionQualityChosenBeforeTheChannelsOpenIsAskedFor() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (laptop, studioID, standIn, received) = try await laptopCallingAStandIn(server)
        defer { laptop.goOffline(); standIn.disconnect() }
        laptop.preferredQuality = .light
        laptop.sessionQuality = .sharp // from an earlier session: cleared when this one starts
        let studio = try #require(laptop.controllable.first)

        let host = try #require(PeerSession(role: .host))
        defer { host.close() }
        let laptopID = laptop.deviceID
        host.onSignal = { payload in
            standIn.send(SignalEnvelope(payload, auth: SessionAuth.sign(payload, to: laptopID, identity: studioID)), to: laptopID)
        }
        host.onInput = { message in DispatchQueue.main.async { received.input.append(message) } }
        standIn.onSignal = { _, envelope in
            received.payloads.append(envelope.payload)
            if case .answer = envelope.payload { host.handle(envelope.payload) }
            if case .candidate = envelope.payload { host.handle(envelope.payload) }
        }

        laptop.connect(to: studio)
        try await poll("request arrives") { received.payloads.contains(.request) }
        #expect(laptop.sessionQuality == nil)
        // Chosen in the session before the channels are open; the saved default stays.
        laptop.sessionQuality = .balanced
        host.start()
        try await poll("quality asked for") { received.input.contains(.quality(.balanced)) }
        try await Task.sleep(for: .milliseconds(500))
        // The session's choice, once, and not the saved Light.
        #expect(received.input.filter { if case .quality = $0 { true } else { false } } == [.quality(.balanced)])
        #expect(laptop.preferredQuality == .light)
    }

    @Test(.timeLimit(.minutes(1)))
    func aWaitingCallCanBeSeenAndCancelled() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (studio, laptop) = try await pairedModels(server)
        defer { studio.goOffline(); laptop.goOffline() }
        let studioAtLaptop = try #require(laptop.controllable.first)

        laptop.goOnline()
        laptop.connect(to: studioAtLaptop)
        #expect(laptop.hostAwaitingServer == studioAtLaptop)
        laptop.disconnect()
        #expect(laptop.hostAwaitingServer == nil)

        // Forgotten while waiting: the wait ends with it.
        laptop.goOnline()
        laptop.connect(to: studioAtLaptop)
        laptop.forget(studioAtLaptop)
        #expect(laptop.hostAwaitingServer == nil)
        try await poll("online again") { laptop.signalingStatus == .online }
        #expect(laptop.controllerStatus == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallMadeWhileReconnectingWaitsForTheServer() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (studio, laptop) = try await pairedModels(server)
        defer { studio.goOffline(); laptop.goOffline() }
        let studioAtLaptop = try #require(laptop.controllable.first)

        // Back from the background: the connection is being made again.
        laptop.goOnline()
        #expect(laptop.signalingStatus != .online)
        laptop.connect(to: studioAtLaptop)
        #expect(laptop.controllerStatus == .idle)
        // Studio does not allow control, so the call may already have been turned away.
        try await poll("calls once online") { laptop.controllerStatus != .idle }
        #expect(laptop.lastHost == studioAtLaptop)
        laptop.disconnect()
        laptop.dismissFailure()

        // Disconnect drops a call still waiting.
        laptop.goOnline()
        laptop.connect(to: studioAtLaptop)
        laptop.disconnect()
        try await poll("online again") { laptop.signalingStatus == .online }
        try await Task.sleep(for: .milliseconds(200))
        #expect(laptop.controllerStatus == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHostThatAnswersKeepsTheCallAlive() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (laptop, _, standIn, received) = try await laptopCallingAStandIn(server)
        defer { laptop.goOffline(); standIn.disconnect() }
        #expect(laptop.callTimeout > laptop.askTimeout) // a host asking first is not given up on
        laptop.callTimeout = 0.8
        laptop.connect(to: try #require(laptop.controllable.first))
        try await poll("request arrives") { received.payloads == [.request] }
        let candidate = SignalPayload.candidate(sdp: "candidate:1 1 udp 1 10.0.0.1 5000 typ host", mLineIndex: 0, mid: "0")
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(500))
            standIn.send(SignalEnvelope(candidate), to: laptop.deviceID)
        }
        try await Task.sleep(for: .milliseconds(300))
        // 1.8 s in, past the timeout, but the host spoke 0.3 s ago.
        if case .calling = laptop.controllerStatus {} else { Issue.record("gave up on a host that answers: \(laptop.controllerStatus)") }
        try await poll("gives up once the host is silent") {
            laptop.controllerStatus == .failed("No answer from Studio. Check that it is awake, online and allows control.")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusalSaysWhy() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (laptop, _, standIn, received) = try await laptopCallingAStandIn(server)
        defer { laptop.goOffline(); standIn.disconnect() }
        let studio = try #require(laptop.controllable.first)

        // An unsigned reason does nothing to a device that is not calling.
        standIn.send(SignalEnvelope(.bye, reason: .notAllowed), to: laptop.deviceID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(laptop.controllerStatus == .idle)

        laptop.connect(to: studio)
        try await poll("request arrives") { received.payloads == [.request] }
        standIn.send(SignalEnvelope(.bye, reason: .stale), to: laptop.deviceID)
        try await poll("reason shown") { laptop.controllerStatus == .failed(BridgeModel.refusal(.stale, from: "Studio")) }
        if case let .failed(message) = laptop.controllerStatus { #expect(message.contains("within a minute")) }
    }

    @Test(.timeLimit(.minutes(1)))
    func aHostTurningARequestAwaySaysWhy() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let (studio, laptop) = try await pairedModels(server)
        defer { studio.goOffline(); laptop.goOffline() }

        // Control is off on Studio.
        laptop.connect(to: try #require(laptop.controllable.first))
        try await poll("not allowed") { laptop.controllerStatus == .failed(BridgeModel.refusal(.notAllowed, from: "Studio")) }

        // A correctly signed request from a clock two minutes off.
        studio.allowsControl = true
        laptop.goOffline()
        let laptopClient = SignalingClient(url: server.url, identity: laptop.identity, accessToken: LocalServer.token)
        defer { laptopClient.disconnect() }
        let received = Received()
        laptopClient.onStatus = { received.online = $0 == .online }
        laptopClient.onSignal = { _, envelope in received.reasons.append(envelope.reason) }
        laptopClient.connect()
        try await poll("laptop key online") { received.online }
        let old = SessionAuth.sign(.request, to: studio.deviceID, identity: laptop.identity, now: Date().addingTimeInterval(-120))
        laptopClient.send(SignalEnvelope(.request, auth: old), to: studio.deviceID)
        try await poll("stale reason") { received.reasons == [.stale] }
        #expect(studio.hostStatus == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedLoginLetsTheMacSleep() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server, token: "not-the-token")
        defer { studio.goOffline() }
        studio.allowsControl = true
        studio.goOnline()
        #expect(studio.power.keepSystemAwake)
        try await poll("refused") { studio.notice == "The server refused the access token." }
        #expect(studio.signalingStatus == .offline)
        #expect(!studio.power.keepSystemAwake)
    }

    @Test(.timeLimit(.minutes(1)))
    func anotherCopyOnlineSaysSoAndStaysOff() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server)
        defer { studio.goOffline() }
        studio.allowsControl = true
        studio.goOnline()
        try await poll("online") { studio.signalingStatus == .online }
        let copy = SignalingClient(url: server.url, identity: studio.identity, accessToken: LocalServer.token)
        defer { copy.disconnect() }
        copy.connect()
        try await poll("told") { studio.notice?.contains("another copy of MacBridge") == true }
        #expect(studio.signalingStatus == .offline)
        #expect(!studio.power.keepSystemAwake)
    }

    @Test(.timeLimit(.minutes(1)))
    func pairingAgainDropsTheCodeShowing() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server)
        defer { studio.goOffline() }
        studio.goOnline()
        try await poll("online") { studio.signalingStatus == .online }
        studio.showPairingCode()
        #expect(shownCode(studio) != nil)
        studio.pair(using: PairingLink(code: PairingCode().display, server: server.url.absoluteString))
        #expect(studio.pairingStatus == .waiting)
    }

    @Test(.timeLimit(.minutes(1)))
    func typingACodeWhileNotOnlineDropsTheScanWaitingForTheServer() async throws {
        let server = try await LocalServer.start()
        let url = server.url.absoluteString
        server.stop() // nobody answers there now
        let phone = makeUnsetModel("Phone")
        phone.serverURL = url
        defer { phone.goOffline() }
        phone.pair(using: PairingLink(code: PairingCode().display, server: url))
        #expect(phone.pairingStatus == .waiting)
        #expect(phone.signalingStatus != .online)
        phone.pair(usingCode: PairingCode().display) // not sent while offline, but the scan stops waiting
        #expect(phone.pairingStatus == .idle)
        try await Task.sleep(for: .milliseconds(100))
        #expect(phone.pairingStatus == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func aShownCodeSurvivesAReconnect() async throws {
        var server = try await LocalServer.start()
        let studio = makeModel("Studio", server: server), laptop = makeModel("Laptop", server: server)
        defer { studio.goOffline(); laptop.goOffline() }
        studio.goOnline()
        try await poll("studio online") { studio.signalingStatus == .online }
        studio.showPairingCode()
        let code = try #require(shownCode(studio))

        server.stop()
        try await poll("studio notices") { studio.signalingStatus != .online }
        server = try await LocalServer.start(port: server.port)
        defer { server.stop() }
        try await poll("studio back") { studio.signalingStatus == .online }
        #expect(shownCode(studio) == code)

        laptop.goOnline()
        try await poll("laptop online") { laptop.signalingStatus == .online }
        try await Task.sleep(for: .milliseconds(200))
        laptop.pair(usingCode: code)
        try await poll("paired with the code shown before the drop") { studio.paired.count == 1 && laptop.paired.count == 1 }
    }

    @Test(.timeLimit(.minutes(1)))
    func comingBackToTheFrontRespectsGoingOffline() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let phone = makeModel("Phone", server: server)
        defer { phone.goOffline() }
        phone.resumeConnection() // never told to stay off: goes online
        try await poll("online") { phone.signalingStatus == .online }

        phone.goOffline()
        phone.resumeConnection()
        try await Task.sleep(for: .milliseconds(300))
        #expect(phone.signalingStatus == .offline)

        // Closing Settings without a change keeps it off; a change lets it come back.
        phone.applyConnectionSettings(server: phone.serverURL, token: nil, loadedServer: phone.serverURL)
        phone.resumeConnection()
        #expect(phone.signalingStatus == .offline)
        phone.applyConnectionSettings(server: phone.serverURL, token: LocalServer.token + "x", loadedServer: phone.serverURL)
        phone.applyConnectionSettings(server: phone.serverURL, token: LocalServer.token, loadedServer: phone.serverURL)
        phone.resumeConnection()
        try await poll("online again") { phone.signalingStatus == .online }
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedLoginStaysOffAndDropsAWaitingConnect() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mac = PairedDevice(id: Identity().deviceID, publicKey: Data(repeating: 7, count: 32), name: "Studio",
                               thisMacMayControl: true)
        defaults.set(try JSONEncoder().encode([mac]), forKey: "pairedDevices")
        let phone = BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory("not-the-token"))
        phone.serverURL = server.url.absoluteString
        defer { phone.goOffline() }

        phone.connect(to: mac) // offline: goes online and connects once the server answers
        #expect(phone.hostAwaitingServer == mac)
        try await poll("refused") { phone.notice == "The server refused the access token." }
        #expect(phone.hostAwaitingServer == nil) // its "server did not answer" must not follow
        phone.resumeConnection()
        try await Task.sleep(for: .milliseconds(300))
        #expect(phone.signalingStatus == .offline)
        #expect(phone.notice == "The server refused the access token.")
    }

    @Test func aTokenTypedForOneServerStaysWithIt() {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = SecretStore.inMemory()
        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: secrets)
        model.applyConnectionSettings(server: "wss://a.example.com", token: "token-a")
        #expect(secrets.token("wss://a.example.com") == "token-a")

        // Settings was filled for A; a pairing link switched to C while a new token was typed.
        model.serverURL = "wss://c.example.com"
        let cToken = secrets.token("wss://c.example.com")
        model.applyConnectionSettings(server: "wss://a.example.com", token: "token-a2", loadedServer: "wss://a.example.com")
        #expect(model.serverURL == "wss://c.example.com") // the switch is not undone
        #expect(secrets.token("wss://a.example.com") == "token-a2")
        #expect(secrets.token("wss://c.example.com") == cToken)

        // Server and token edited together: the token goes to the new server, the old keeps its own.
        model.applyConnectionSettings(server: "wss://b.example.com", token: "token-b", loadedServer: "wss://c.example.com")
        #expect(model.serverURL == "wss://b.example.com")
        #expect(secrets.token("wss://b.example.com") == "token-b")
        #expect(secrets.token("wss://c.example.com") == cToken)
        #expect(secrets.token("wss://a.example.com") == "token-a2")
    }

    /// A model with a token but no server yet, as on first launch.
    private func makeUnsetModel(_ name: String, token: String = LocalServer.token) -> BridgeModel {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory(token))
        model.deviceName = name
        return model
    }

    @Test(.timeLimit(.minutes(1)))
    func firstTimeSetupWithoutATokenPairsFromOneScan() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let phone = makeUnsetModel("Phone", token: "")
        defer { phone.goOffline() }
        phone.pair(using: PairingLink(code: PairingCode().display, server: server.url.absoluteString))
        #expect(phone.pairingStatus == .waiting) // no question first
        #expect(phone.serverURL == server.url.absoluteString)
    }

    @Test(.timeLimit(.minutes(1)))
    func firstTimeSetupWithATokenAsksThenPairs() async throws {
        let server = try await LocalServer.start()
        defer { server.stop() }
        let studio = makeModel("Studio", server: server), phone = makeUnsetModel("Phone")
        defer { studio.goOffline(); phone.goOffline() }
        studio.goOnline()
        try await poll("studio online") { studio.signalingStatus == .online }
        studio.showPairingCode()
        let code = try #require(shownCode(studio))
        try await Task.sleep(for: .milliseconds(200))

        // The token was entered with no server: a link must not take it without a yes.
        phone.pair(using: PairingLink(code: code, server: server.url.absoluteString))
        #expect(phone.pairingStatus == .confirmServer(server.url.absoluteString, sendsToken: true))
        #expect(phone.serverURL == "")
        phone.confirmServerSwitch()
        try await poll("paired") { studio.paired.count == 1 && phone.paired.count == 1 }
        #expect(phone.serverURL == server.url.absoluteString)
        #expect(phone.accessToken == LocalServer.token)
    }

    @Test func anUnusableServerWithATokenStillAsks() throws {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = SecretStore.inMemory()
        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: secrets)
        model.applyConnectionSettings(server: "wss://a.example.com", token: "token-a")
        // The field cleared, or left half-typed: the token stays on screen with no server.
        model.applyConnectionSettings(server: "not a server", token: nil)
        #expect(model.accessToken == "token-a" && !model.canGoOnline)

        model.pair(using: PairingLink(code: PairingCode().display, server: "ws://127.0.0.1:1"))
        #expect(model.pairingStatus == .confirmServer("ws://127.0.0.1:1", sendsToken: true))
        #expect(model.serverURL == "not a server")
        model.cancelPairing()
        #expect(model.serverURL == "not a server" && secrets.token("ws://127.0.0.1:1") == "")
        #expect(secrets.token("wss://a.example.com") == "token-a")
    }

    @Test(.timeLimit(.minutes(1)))
    func aLinkToAnotherServerAsksAndNeverSendsTheToken() async throws {
        let server = try await LocalServer.start(), other = try await LocalServer.start()
        defer { server.stop(); other.stop() }
        let phone = makeModel("Phone", server: server)
        defer { phone.goOffline() }
        phone.goOnline()
        try await poll("phone online") { phone.signalingStatus == .online }

        let link = PairingLink(code: PairingCode().display, server: other.url.absoluteString)
        phone.pair(using: link)
        #expect(phone.pairingStatus == .confirmServer(other.url.absoluteString, sendsToken: false))
        #expect(phone.serverURL == server.url.absoluteString)
        #expect(phone.accessToken == LocalServer.token)
        #expect(phone.signalingStatus == .online)

        // Cancelled: nothing changes.
        phone.cancelPairing()
        phone.confirmServerSwitch()
        #expect(phone.serverURL == server.url.absoluteString)

        // Confirmed: the new server gets no token, so it refuses this device.
        phone.pair(using: link)
        phone.confirmServerSwitch()
        #expect(phone.serverURL == other.url.absoluteString)
        #expect(phone.accessToken == "")
        try await poll("refused for lack of a token") { phone.notice == "The server refused the access token." }

        // The first server's token is still kept for it.
        phone.serverURL = server.url.absoluteString
        #expect(phone.accessToken == LocalServer.token)
    }

    @Test func tokensAreKeptPerServer() throws {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://a.example.com/", forKey: "serverURL")
        let secrets = SecretStore.inMemory("old-single-token")

        // The one token of an older version belongs to the server saved then.
        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: secrets)
        #expect(model.accessToken == "old-single-token")
        #expect(secrets.token("wss://a.example.com") == "old-single-token")
        #expect(secrets.token("") == "")

        // Committing another server in Settings loads its own token; neither server loses its own.
        secrets.setToken("token-b", "wss://b.example.com:8443")
        model.applyConnectionSettings(server: "wss://B.example.com:8443/", token: nil)
        #expect(model.accessToken == "token-b")
        #expect(secrets.token("wss://a.example.com") == "old-single-token")
        model.applyConnectionSettings(server: "wss://a.example.com", token: nil)
        #expect(model.accessToken == "old-single-token")
        #expect(secrets.token("wss://b.example.com:8443") == "token-b")

        // A new server gets a copy of the token shown; the old one keeps it.
        model.applyConnectionSettings(server: "wss://c.example.com", token: nil)
        #expect(model.accessToken == "old-single-token")
        #expect(secrets.token("wss://a.example.com") == "old-single-token")
        model.applyConnectionSettings(server: "wss://c.example.com", token: "token-c")
        #expect(secrets.token("wss://c.example.com") == "token-c")
        #expect(secrets.token("wss://a.example.com") == "old-single-token")
        #expect(BridgeModel(identity: Identity(), defaults: defaults, secrets: secrets).accessToken == "token-c")
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

    @Test func theQualityPresetSurvivesARestart() throws {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory()).preferredQuality == .sharp)
        // The key and the Int the views wrote before the model kept it.
        defaults.set(Int(QualityPreset.balanced.rawValue), forKey: "qualityPreset")
        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory())
        #expect(model.preferredQuality == .balanced)
        model.preferredQuality = .light
        #expect(BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory()).preferredQuality == .light)
    }

    @Test func namesFromOtherDevicesAreMadeSafeToShow() {
        #expect(BridgeModel.label("  Studio\n", id: "abcdefgh") == "Studio")
        #expect(BridgeModel.label("", id: "abcdefgh") == "Mac abcd")
        #expect(BridgeModel.label("a\u{07}b\u{1B}c", id: "abcdefgh") == "abc")
        #expect(BridgeModel.label(String(repeating: "x", count: 500), id: "abcdefgh").count == 64)
    }
}

/// What a bare client received, written on the main queue.
private final class Received: @unchecked Sendable {
    var online = false
    var payloads: [SignalPayload] = []
    var reasons: [ByeReason?] = []
    var input: [InputMessage] = []
}
