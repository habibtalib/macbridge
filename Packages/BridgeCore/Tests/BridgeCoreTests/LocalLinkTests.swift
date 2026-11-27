import Foundation
import Network
import Testing
@testable import BridgeCore

/// Two links over loopback, without Bonjour: one listens like a Mac that accepts control, the
/// other dials it like a controller that found it on the network.
@Suite(.serialized)
struct LocalLinkTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _peers: Set<String> = []
        private var _signals: [(String, SignalEnvelope)] = []
        var peers: Set<String> { lock.withLock { _peers } }
        var signals: [(String, SignalEnvelope)] { lock.withLock { _signals } }
        func attach(_ link: LocalLink) {
            link.onPeers = { peers in self.lock.withLock { self._peers = peers } }
            link.onSignal = { from, envelope in self.lock.withLock { self._signals.append((from, envelope)) } }
        }
    }

    private func device(_ identity: Identity, _ name: String) -> PairedDevice {
        PairedDevice(id: identity.deviceID, publicKey: identity.publicKey, name: name,
                     mayControlThisMac: true, thisMacMayControl: true)
    }

    private func listening(_ identity: Identity, peers: [PairedDevice]) async throws -> (LocalLink, NWEndpoint) {
        let link = LocalLink(identity: identity, usesBonjour: false)
        link.start(peers: peers, advertise: true)
        try await poll("listening") { link.port != nil }
        return (link, .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: link.port!)!))
    }

    @Test(.timeLimit(.minutes(1)))
    func pairedDevicesConnectAndExchangeSignals() async throws {
        let mini = Identity(), laptop = Identity()
        let (host, endpoint) = try await listening(mini, peers: [device(laptop, "Laptop")])
        let controller = LocalLink(identity: laptop, usesBonjour: false)
        defer { host.stop(); controller.stop() }
        let hostBox = Box(), controllerBox = Box()
        hostBox.attach(host); controllerBox.attach(controller)
        controller.start(peers: [device(mini, "Mini")], advertise: false)
        controller.dial(endpoint, expecting: mini.deviceID)

        try await poll("both verified") {
            hostBox.peers == [laptop.deviceID] && controllerBox.peers == [mini.deviceID]
        }
        #expect(controller.isReachable(mini.deviceID))

        let request = SignalEnvelope(.request, auth: SessionAuth.sign(.request, to: mini.deviceID, identity: laptop))
        #expect(controller.send(request, to: mini.deviceID))
        try await poll("request arrives") { hostBox.signals.count == 1 }
        #expect(hostBox.signals.first?.0 == laptop.deviceID)
        #expect(hostBox.signals.first?.1 == request)

        #expect(host.send(SignalEnvelope(.bye, reason: .notAllowed), to: laptop.deviceID))
        try await poll("reply arrives") { controllerBox.signals.count == 1 }
        #expect(controllerBox.signals.first?.1.reason == .notAllowed)

        // Not reachable here: the caller falls back to the server.
        #expect(!controller.send(request, to: Identity().deviceID))

        host.stop()
        try await poll("drop noticed") { controllerBox.peers.isEmpty }
    }

    @Test(.timeLimit(.minutes(1)))
    func forgettingADeviceDropsItAtOnce() async throws {
        let mini = Identity(), laptop = Identity()
        let (host, endpoint) = try await listening(mini, peers: [device(laptop, "Laptop")])
        let controller = LocalLink(identity: laptop, usesBonjour: false)
        defer { host.stop(); controller.stop() }
        let hostBox = Box()
        hostBox.attach(host)
        controller.start(peers: [device(mini, "Mini")], advertise: false)
        controller.dial(endpoint, expecting: mini.deviceID)
        try await poll("verified") { hostBox.peers == [laptop.deviceID] }

        host.setPeers([])
        #expect(!host.isReachable(laptop.deviceID))
        #expect(!host.send(SignalEnvelope(.bye), to: laptop.deviceID))
        try await poll("reported") { hostBox.peers.isEmpty }
    }

    @Test(.timeLimit(.minutes(1)))
    func unpairedDeviceIsTurnedAway() async throws {
        let mini = Identity(), laptop = Identity(), stranger = Identity()
        let (host, endpoint) = try await listening(mini, peers: [device(laptop, "Laptop")])
        // The stranger knows the Mac's key, but the Mac never paired with it.
        let intruder = LocalLink(identity: stranger, usesBonjour: false)
        defer { host.stop(); intruder.stop() }
        let hostBox = Box(), intruderBox = Box()
        hostBox.attach(host); intruderBox.attach(intruder)
        intruder.start(peers: [device(mini, "Mini")], advertise: false)
        intruder.dial(endpoint, expecting: mini.deviceID)

        try await Task.sleep(for: .seconds(2))
        #expect(hostBox.peers.isEmpty)
        #expect(intruderBox.peers.isEmpty)
        #expect(!intruder.send(SignalEnvelope(.request), to: mini.deviceID))
    }

    @Test func proofBindsKeyNonceAndBothIDs() {
        let mini = Identity(), laptop = Identity(), impostor = Identity()
        let nonce = Data(repeating: 7, count: LocalLink.nonceBytes)
        let message = LocalLink.proof(nonce: nonce, prover: laptop.deviceID, verifier: mini.deviceID)
        #expect(Identity.verify(laptop.sign(message), of: message, publicKey: laptop.publicKey))
        // Someone claiming the laptop's ID without its key.
        #expect(!Identity.verify(impostor.sign(message), of: message, publicKey: laptop.publicKey))
        // A proof recorded for another nonce or another Mac does not carry over.
        let otherNonce = LocalLink.proof(nonce: Data(repeating: 8, count: LocalLink.nonceBytes), prover: laptop.deviceID, verifier: mini.deviceID)
        let otherMac = LocalLink.proof(nonce: nonce, prover: laptop.deviceID, verifier: impostor.deviceID)
        #expect(!Identity.verify(laptop.sign(otherNonce), of: message, publicKey: laptop.publicKey))
        #expect(!Identity.verify(laptop.sign(otherMac), of: message, publicKey: laptop.publicKey))
    }

    /// Over Bonjour on this machine. Opt-in: it advertises a service on the local network.
    @Test(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["MACBRIDGE_BONJOUR_TEST"] == "1"))
    func findsEachOtherWithBonjour() async throws {
        let mini = Identity(), laptop = Identity()
        let host = LocalLink(identity: mini), controller = LocalLink(identity: laptop)
        defer { host.stop(); controller.stop() }
        let hostBox = Box(), controllerBox = Box()
        hostBox.attach(host); controllerBox.attach(controller)
        host.start(peers: [device(laptop, "Laptop")], advertise: true)
        controller.start(peers: [device(mini, "Mini")], advertise: false)
        try await poll("found and verified") { controllerBox.peers == [mini.deviceID] && hostBox.peers == [laptop.deviceID] }
    }

    @Test func onlyOneSideDials() {
        let a = "aaaaaaaaaaaaaaaa", b = "bbbbbbbbbbbbbbbb"
        // Both advertise: the smaller ID dials, the other waits.
        #expect(LocalLink.shouldDial(ownID: a, peerID: b, advertises: true))
        #expect(!LocalLink.shouldDial(ownID: b, peerID: a, advertises: true))
        // A device nobody can find (an iPhone, a Mac that does not accept control) always dials.
        #expect(LocalLink.shouldDial(ownID: b, peerID: a, advertises: false))
    }
}
