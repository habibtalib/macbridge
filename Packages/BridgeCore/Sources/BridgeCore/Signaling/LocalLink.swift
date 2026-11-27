import Foundation
import Network

/// Session setup between paired devices on the same local network, without the signaling
/// server. A Mac that accepts control advertises itself with Bonjour (`_macbridge._tcp`, named
/// by its device ID); every device looks for the paired devices it knows and opens a TCP
/// connection to them. Each message is JSON after its length (4 bytes, big-endian).
///
/// Both ends prove who they are before anything else travels: each sends a random nonce and
/// signs the other's with its identity key, checked against the key stored at pairing. A
/// device that was never paired cannot get past that, so only paired devices ever exchange
/// setup messages here. The messages themselves carry the same end-to-end signatures as over
/// the server, and the screen and input still travel over WebRTC.
///
/// Callbacks are delivered on the main queue.
public final class LocalLink: @unchecked Sendable {
    public static let serviceType = "_macbridge._tcp"
    static let maxMessageBytes = 64 * 1024
    /// Connections not yet past the handshake; more are refused, in all and from one address.
    static let maxUnverified = 16
    static let maxUnverifiedPerAddress = 4
    /// Longest pause between attempts to dial a device that keeps failing.
    static let maxRedialDelay: TimeInterval = 300
    static let nonceBytes = 32
    private static let proofPrefix = Data("macbridge-local-v1".utf8)

    /// Internal so tests can shorten them; set before `start`.
    var handshakeTimeout: TimeInterval = 5
    var pingInterval: TimeInterval = 5
    var idleTimeout: TimeInterval = 15
    var redialDelay: TimeInterval = 3

    /// A setup message from a paired device that proved who it is.
    public var onSignal: ((_ from: String, SignalEnvelope) -> Void)?
    /// The paired devices reachable on the local network right now.
    public var onPeers: ((Set<String>) -> Void)?

    private let identity: Identity
    private let ownID: String
    /// Without Bonjour (tests): no service is advertised or looked for; `dial` and `port` instead.
    private let usesBonjour: Bool
    private let queue = DispatchQueue(label: "macbridge.local")

    // Guarded by `queue`.
    private var running = false
    private var advertises = false
    private var keys: [String: Data] = [:]
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var browseResults: Set<NWBrowser.Result> = []
    private var found: [String: NWEndpoint] = [:]
    private var links: [ObjectIdentifier: Link] = [:]
    private var verified: [String: Link] = [:]
    private var reported: Set<String> = []
    private var pingTimer: DispatchSourceTimer?
    private var listenerPort: UInt16?
    /// Failed dials in a row per device, and when it may be dialed again.
    private var failures: [String: Int] = [:]
    private var nextDial: [String: Date] = [:]

    private final class Link {
        let connection: NWConnection
        let nonce: Data
        /// The device dialed, for an outgoing connection.
        let dialed: String?
        var peerID: String?
        var isVerified = false
        var lastHeard = Date()

        init(_ connection: NWConnection, dialed: String?) {
            self.connection = connection
            self.dialed = dialed
            var bytes = [UInt8](repeating: 0, count: LocalLink.nonceBytes)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            nonce = Data(bytes)
        }
    }

    private struct Wire: Codable {
        var t: String
        var id: String?
        var nonce: Data?
        var sig: Data?
        var data: SignalEnvelope?
    }

    public init(identity: Identity, usesBonjour: Bool = true) {
        self.identity = identity
        ownID = identity.deviceID
        self.usesBonjour = usesBonjour
    }

    // MARK: - Control

    /// Starts listening (when advertising) and looking for `peers`.
    public func start(peers: [PairedDevice], advertise: Bool) {
        queue.async {
            self.keys = Self.keyTable(peers)
            self.advertises = advertise
            guard !self.running else { return self.restartListener() }
            self.running = true
            self.restartListener()
            self.startBrowsing()
            self.startPinging()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.listener?.cancel(); self.listener = nil; self.listenerPort = nil
            self.browser?.cancel(); self.browser = nil
            self.browseResults = []; self.found = [:]
            self.pingTimer?.cancel(); self.pingTimer = nil
            for link in self.links.values { link.connection.cancel() }
            self.links = [:]
            self.verified = [:]
            self.report()
        }
    }

    /// The paired devices changed: a device no longer paired is dropped at once.
    public func setPeers(_ peers: [PairedDevice]) {
        queue.async {
            self.keys = Self.keyTable(peers)
            for link in self.links.values where link.peerID.map({ self.keys[$0] == nil }) ?? false {
                link.connection.cancel()
            }
            // Gone at once, not when the cancelled connection reports back.
            for id in self.verified.keys where self.keys[id] == nil { self.verified[id] = nil }
            self.report()
            self.updateFound()
        }
    }

    /// Advertises this device (it accepts control) or stops doing so.
    public func setAdvertising(_ advertise: Bool) {
        queue.async {
            guard self.advertises != advertise else { return }
            self.advertises = advertise
            if self.running { self.restartListener() }
        }
    }

    /// Sends to `peer` if it is reachable here. Returns false otherwise, for the caller to use
    /// the server instead.
    @discardableResult
    public func send(_ envelope: SignalEnvelope, to peer: String) -> Bool {
        queue.sync {
            guard let link = verified[peer] else { return false }
            write(Wire(t: "signal", data: envelope), on: link)
            return true
        }
    }

    public func isReachable(_ peer: String) -> Bool {
        queue.sync { verified[peer] != nil }
    }

    /// Who dials when both devices could: a device that does not advertise always dials (no one
    /// could reach it), and of two that advertise the one with the smaller ID dials, so they do
    /// not open two connections to each other.
    static func shouldDial(ownID: String, peerID: String, advertises: Bool) -> Bool {
        !advertises || ownID < peerID
    }

    // MARK: - For tests (no Bonjour)

    /// The port listened on, once listening.
    var port: UInt16? { queue.sync { listenerPort } }

    /// Opens a connection to `endpoint`, expected to be `peerID`.
    func dial(_ endpoint: NWEndpoint, expecting peerID: String) {
        queue.async { self.open(endpoint, dialed: peerID) }
    }

    // MARK: - Listening and browsing

    private static func keyTable(_ peers: [PairedDevice]) -> [String: Data] {
        Dictionary(peers.map { ($0.id, $0.publicKey) }, uniquingKeysWith: { first, _ in first })
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        listenerPort = nil
        guard running, advertises else { return }
        guard let listener = try? NWListener(using: Self.parameters()) else {
            PeerSession.writeStats("local: could not listen")
            return
        }
        if usesBonjour {
            listener.service = NWListener.Service(name: ownID, type: Self.serviceType)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let unverified = self.links.values.filter { !$0.isVerified }
            let address = Self.address(connection.endpoint)
            if unverified.count >= Self.maxUnverified
                || unverified.filter({ Self.address($0.connection.endpoint) == address }).count >= Self.maxUnverifiedPerAddress {
                return connection.cancel()
            }
            self.start(Link(connection, dialed: nil))
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.listenerPort = listener.port?.rawValue
            case let .failed(error):
                PeerSession.writeStats("local: listener failed: \(error)")
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.listener == nil else { return }
                    self.restartListener()
                }
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func startBrowsing() {
        guard usesBonjour else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            self.browseResults = results
            self.updateFound()
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            if case let .failed(error) = state {
                PeerSession.writeStats("local: browsing failed: \(error)")
                self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.running, self.browser == nil else { return }
                    self.startBrowsing()
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private static func address(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    private func updateFound() {
        var found: [String: NWEndpoint] = [:]
        for result in browseResults {
            guard case let .service(name, _, _, _) = result.endpoint,
                  name != ownID, keys[name] != nil else { continue }
            found[name] = result.endpoint
        }
        // A device that shows up again (back on the network) is dialed without waiting out its backoff.
        for id in found.keys where self.found[id] == nil { failures[id] = nil; nextDial[id] = nil }
        self.found = found
        dialFound()
    }

    private func dialFound() {
        guard running else { return }
        let now = Date()
        for (id, endpoint) in found
        where (nextDial[id].map { $0 <= now } ?? true)
            && Self.shouldDial(ownID: ownID, peerID: id, advertises: advertises)
            && verified[id] == nil && !links.values.contains(where: { $0.dialed == id || $0.peerID == id }) {
            open(endpoint, dialed: id)
        }
    }

    private func startPinging() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for link in self.verified.values {
                if now.timeIntervalSince(link.lastHeard) > self.idleTimeout {
                    PeerSession.writeStats("local: \(link.peerID ?? "?") went quiet")
                    link.connection.cancel()
                } else {
                    self.write(Wire(t: "ping"), on: link)
                }
            }
        }
        pingTimer = timer
        timer.resume()
    }

    // MARK: - Connections

    private func open(_ endpoint: NWEndpoint, dialed peerID: String) {
        start(Link(NWConnection(to: endpoint, using: Self.parameters()), dialed: peerID))
    }

    private func start(_ link: Link) {
        links[ObjectIdentifier(link)] = link
        link.connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                self.write(Wire(t: "hello", id: self.ownID, nonce: link.nonce), on: link)
                self.receive(on: link)
            case .failed, .cancelled:
                self.closed(link)
            case let .waiting(error):
                // No route (yet): give up on this attempt; a later browse result dials again.
                PeerSession.writeStats("local: waiting: \(error)")
                link.connection.cancel()
            default:
                break
            }
        }
        link.connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak link] in
            guard let link, !link.isVerified else { return }
            link.connection.cancel()
        }
    }

    private func closed(_ link: Link) {
        guard links.removeValue(forKey: ObjectIdentifier(link)) != nil else { return }
        if let id = link.peerID, verified[id] === link {
            verified[id] = nil
            PeerSession.writeStats("local: \(id) disconnected")
            report()
        }
        // A device still advertised is dialed again after a pause: the network may have changed.
        // One that keeps failing (it no longer knows this device, no route) waits longer each time.
        if let id = link.dialed, running {
            let count = link.isVerified ? 0 : (failures[id] ?? 0) + 1
            failures[id] = count
            let delay = min(redialDelay * pow(2, Double(max(count - 1, 0))), Self.maxRedialDelay)
            nextDial[id] = Date().addingTimeInterval(delay)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.found[id] != nil else { return }
                self.dialFound()
            }
        }
    }

    private func receive(on link: Link) {
        link.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak link] header, _, isComplete, error in
            guard let self, let link else { return }
            guard error == nil, let header, header.count == 4 else { return link.connection.cancel() }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= Self.maxMessageBytes, !isComplete else { return link.connection.cancel() }
            link.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak link] content, _, _, error in
                guard let self, let link else { return }
                guard error == nil, let content, content.count == length,
                      let message = try? JSONDecoder().decode(Wire.self, from: content) else {
                    return link.connection.cancel()
                }
                link.lastHeard = Date()
                self.handle(message, on: link)
                if self.links[ObjectIdentifier(link)] != nil { self.receive(on: link) }
            }
        }
    }

    private func handle(_ message: Wire, on link: Link) {
        switch message.t {
        case "hello":
            guard link.peerID == nil, let id = message.id, id != ownID, keys[id] != nil,
                  link.dialed == nil || link.dialed == id,
                  let nonce = message.nonce, nonce.count == Self.nonceBytes else {
                return link.connection.cancel()
            }
            link.peerID = id
            let proof = identity.sign(Self.proof(nonce: nonce, prover: ownID, verifier: id))
            write(Wire(t: "proof", sig: proof), on: link)
        case "proof":
            guard let id = link.peerID, !link.isVerified, let key = keys[id], let signature = message.sig,
                  Identity.verify(signature, of: Self.proof(nonce: link.nonce, prover: id, verifier: ownID), publicKey: key) else {
                return link.connection.cancel()
            }
            link.isVerified = true
            // A newer connection replaces an older one: the older one is most likely dead
            // (a network change), or the two devices dialed each other at once.
            if let old = verified[id], old !== link { old.connection.cancel() }
            verified[id] = link
            failures[id] = nil
            nextDial[id] = nil
            PeerSession.writeStats("local: \(id) connected")
            report()
        case "signal":
            guard link.isVerified, let id = link.peerID, let envelope = message.data else { return }
            DispatchQueue.main.async { self.onSignal?(id, envelope) }
        case "ping":
            if link.isVerified { write(Wire(t: "pong"), on: link) }
        default:
            break // "pong", or something newer: having heard from it is enough
        }
    }

    static func proof(nonce: Data, prover: String, verifier: String) -> Data {
        proofPrefix + nonce + Data(prover.utf8) + Data(verifier.utf8)
    }

    private func write(_ message: Wire, on link: Link) {
        guard let data = try? JSONEncoder().encode(message), data.count <= Self.maxMessageBytes else { return }
        let length = UInt32(data.count)
        let header = Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        // A write that fails means the connection is gone: drop it now, not when pings go unanswered.
        link.connection.send(content: header + data, completion: .contentProcessed { [weak link] error in
            if error != nil { link?.connection.cancel() }
        })
    }

    private func report() {
        let now = Set(verified.keys)
        guard now != reported else { return }
        reported = now
        DispatchQueue.main.async { self.onPeers?(now) }
    }
}
