import Foundation
import Network

/// Why a host turned a request away, sent with its `bye`. Unsigned like the `bye` itself: it
/// can only end a call that is still waiting for that host, which a plain `bye` could too.
public enum ByeReason: String, Sendable, Codable {
    /// This device may not control the host, or the host does not allow control right now.
    case notAllowed = "not-allowed"
    /// The request's time was too far from the host's clock.
    case stale
    /// The host may not record its screen.
    case noScreenPermission = "no-screen-permission"
}

/// A setup message plus, where required, the sender's proof of identity.
public struct SignalEnvelope: Equatable, Sendable, Codable {
    public var payload: SignalPayload
    public var auth: SignalAuth?
    /// Only on a `bye`. Older apps ignore it; a reason this app does not know reads as nil.
    public var reason: ByeReason?

    public init(_ payload: SignalPayload, auth: SignalAuth? = nil, reason: ByeReason? = nil) {
        self.payload = payload
        self.auth = auth
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case auth, reason }

    public init(from decoder: Decoder) throws {
        payload = try SignalPayload(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auth = try c.decodeIfPresent(SignalAuth.self, forKey: .auth)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)).flatMap(ByeReason.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(auth, forKey: .auth)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

/// WebSocket connection to the signaling server. Logs in by proving it holds
/// the identity key, then stays connected: if the socket drops it reconnects
/// with backoff until `disconnect()` is called. A ping that goes unanswered
/// counts as a drop, and a network change reconnects at once.
///
/// Callbacks are delivered on the main queue.
public final class SignalingClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case offline
        case connecting
        case online
    }

    public enum ServerError: Equatable, Sendable {
        /// The device a message was addressed to is not connected.
        case peerOffline(String)
        /// Nobody is waiting for that pairing code.
        case noSuchPairing
        /// The server refused the login (wrong access token or key). The
        /// client stops reconnecting; retrying cannot succeed.
        case unauthorized(String)
        /// Another connection logged in with this identity (another copy of the
        /// app with the same key). The client stops reconnecting, or the two would
        /// take turns pushing each other off.
        case replaced
        /// The server does not know a message of this type. It stays connected.
        case unsupported(String)
        case other(String)
    }

    public var onStatus: ((Status) -> Void)?
    public var onSignal: ((_ from: String, SignalEnvelope) -> Void)?
    public var onError: ((ServerError) -> Void)?
    /// A device that typed our pairing code introduces itself.
    public var onPairRequest: ((_ from: String, _ sealed: Data) -> Void)?
    /// The device whose code we typed answers.
    public var onPairReply: ((_ from: String, _ sealed: Data) -> Void)?

    /// How often an online connection is checked, and how long the pong may take.
    /// Internal so tests can shorten them; set before `connect()`.
    var pingInterval: TimeInterval = 20
    var pingTimeout: TimeInterval = 10
    /// A connection not logged in by then is dropped; pings only start once online.
    var loginTimeout: TimeInterval = 15

    /// The server's close code for a connection taken over by the same identity.
    static let replacedCloseCode = 4001
    /// Most IDs the server answers in one presence request.
    static let presenceBatch = 64

    public let url: URL
    private let identity: Identity
    private let accessToken: String?
    private let queue = DispatchQueue(label: "macbridge.signaling")

    // Guarded by `queue`.
    /// Holds this client as its delegate until invalidated in `stop()`.
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    /// The task dropped last, until the next one opens: its close code may arrive after the drop.
    private var droppedTask: URLSessionWebSocketTask?
    private var wantsConnection = false
    private var attempt = 0
    private var status: Status = .offline
    private var iceWaiters: [([IceServer]) -> Void] = []
    /// One per presence request sent, in order: the server answers them in the order asked.
    /// A request that timed out keeps its place, so later answers still go to the right one.
    private var presenceWaiters: [(Set<String>?) -> Void] = []
    /// A server that does not know presence answers "unsupported": ask once, then never again.
    private var presenceUnsupported = false
    /// A server from before presence and "unsupported" existed closes the connection with
    /// bad-message instead. Twice in a row with presence asked, and presence is off.
    private var presenceStrikes = 0
    /// The ping waiting for its pong.
    private var pingNumber = 0
    private var awaitedPing: Int?
    private var pathMonitor: NWPathMonitor?
    private var lastPath: (satisfied: Bool, interfaces: [String])?

    public init(url: URL, identity: Identity, accessToken: String? = nil) {
        self.url = url
        self.identity = identity
        self.accessToken = accessToken?.isEmpty == false ? accessToken : nil
    }

    public func connect() {
        queue.async {
            guard !self.wantsConnection else { return }
            self.wantsConnection = true
            self.attempt = 0
            self.watchNetwork()
            self.open()
        }
    }

    public func disconnect() {
        queue.async { self.stop() }
    }

    /// The device woke up or the app came to the front: the connection may be dead without
    /// anything having said so. Online, a ping checks it now; otherwise it reconnects now,
    /// without waiting out the backoff.
    public func reconnectIfStale() {
        queue.async {
            guard self.wantsConnection else { return }
            self.attempt = 0
            if let task = self.task, self.status == .online {
                self.ping(task)
            } else {
                self.reconnectNow()
            }
        }
    }

    public func send(_ envelope: SignalEnvelope, to peer: String) {
        write(.signal(to: peer, data: envelope))
    }

    /// Asks the server for STUN/TURN servers with fresh credentials.
    /// Completes on the main queue with an empty list if the server does not
    /// answer in time; a direct connection may still work without them.
    public func requestIceServers(timeout: TimeInterval = 3, completion: @escaping ([IceServer]) -> Void) {
        queue.async {
            guard let task = self.task, self.status == .online else {
                return DispatchQueue.main.async { completion([]) }
            }
            var finished = false
            let finish: ([IceServer]) -> Void = { servers in
                guard !finished else { return }
                finished = true
                DispatchQueue.main.async { completion(servers) }
            }
            self.iceWaiters.append(finish)
            self.write(.ice, on: task)
            self.queue.asyncAfter(deadline: .now() + timeout) { finish([]) }
        }
    }

    /// Asks which of these devices are connected to the server. `completion` gets the connected ones,
    /// or nil when the server gave no answer (offline, or a server from before this request existed).
    /// More IDs than the server takes at once are asked in batches.
    public func presence(of ids: [String], timeout: TimeInterval = 3, completion: @escaping (Set<String>?) -> Void) {
        queue.async {
            guard let task = self.task, self.status == .online, !self.presenceUnsupported, !ids.isEmpty else {
                return DispatchQueue.main.async { completion(nil) }
            }
            var finished = false
            let finish: (Set<String>?) -> Void = { online in
                guard !finished else { return }
                finished = true
                DispatchQueue.main.async { completion(online) }
            }
            let batches = stride(from: 0, to: ids.count, by: Self.presenceBatch).map {
                Array(ids[$0 ..< min($0 + Self.presenceBatch, ids.count)])
            }
            var waiting = batches.count
            var online = Set<String>()
            for batch in batches {
                self.presenceWaiters.append { answer in
                    guard let answer else { return finish(nil) }
                    online.formUnion(answer)
                    waiting -= 1
                    if waiting == 0 { finish(online) }
                }
                self.write(.presence(ids: batch), on: task)
            }
            // Only this request gives up; its waiters stay queued for answers still on the way.
            self.queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    public func openPairing(tag: String) { write(.pairOpen(tag: tag)) }
    public func closePairing() { write(.pairClose) }
    public func sendPairRequest(tag: String, sealed: Data) { write(.pair(tag: tag, sealed: sealed)) }
    public func sendPairReply(to peer: String, sealed: Data) { write(.pairReply(to: peer, sealed: sealed)) }

    // MARK: - Connection

    private func open() {
        set(.connecting)
        let session = self.session ?? URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 256 * 1024
        self.task = task
        droppedTask = nil
        task.resume()
        write(.hello(id: identity.deviceID, key: identity.publicKey, token: accessToken), on: task)
        receive(on: task)
        queue.asyncAfter(deadline: .now() + loginTimeout) {
            guard task === self.task, self.status != .online else { return }
            self.dropped(task)
        }
    }

    private func stop() {
        wantsConnection = false
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        if let task { discard(task) }
        // A URLSession keeps its delegate until invalidated: without this the
        // client, and the model it calls back, would never be freed.
        session?.invalidateAndCancel()
        session = nil
        set(.offline)
    }

    /// Lets go of the current task and fails everything waiting on it.
    private func discard(_ task: URLSessionWebSocketTask) {
        if task === self.task { self.task = nil }
        droppedTask = task
        awaitedPing = nil
        task.cancel(with: .goingAway, reason: nil)
        flushIceWaiters()
        flushPresenceWaiters()
    }

    /// Drops the current connection, if any, and opens a new one at once.
    private func reconnectNow() {
        guard wantsConnection else { return }
        if let task { discard(task) }
        attempt = 0
        open()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard task === self.task else { return }
                switch result {
                case let .success(message):
                    self.handle(message, on: task)
                    self.receive(on: task)
                case .failure:
                    self.dropped(task)
                }
            }
        }
    }

    private func dropped(_ task: URLSessionWebSocketTask, closeCode: Int? = nil) {
        guard task === self.task else { return }
        discard(task)
        guard wantsConnection else { return set(.offline) }
        if (closeCode ?? task.closeCode.rawValue) == Self.replacedCloseCode { return replaced() }
        set(.connecting)
        attempt += 1
        let delay = min(30, pow(2, Double(attempt - 1)))
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.wantsConnection, self.task == nil else { return }
            self.open()
        }
    }

    /// Another copy logged in with this identity. Reconnecting would push it off in turn.
    private func replaced() {
        stop()
        DispatchQueue.main.async { self.onError?(.replaced) }
    }

    // MARK: Keepalive and network changes

    private func schedulePing(_ task: URLSessionWebSocketTask) {
        queue.asyncAfter(deadline: .now() + pingInterval) {
            guard task === self.task, self.status == .online, self.awaitedPing == nil else { return }
            self.ping(task)
        }
    }

    /// A socket can die without a close (sleep, a network that went away): no pong in time
    /// counts as a drop.
    private func ping(_ task: URLSessionWebSocketTask) {
        guard awaitedPing == nil else { return } // one already on its way checks the same thing
        pingNumber += 1
        let number = pingNumber
        awaitedPing = number
        task.sendPing { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard task === self.task, self.awaitedPing == number else { return }
                if error != nil { return self.dropped(task) }
                self.awaitedPing = nil
                self.schedulePing(task)
            }
        }
        queue.asyncAfter(deadline: .now() + pingTimeout) {
            guard task === self.task, self.awaitedPing == number else { return }
            self.dropped(task)
        }
    }

    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// Back on a network, or on another one: the old socket is likely dead or about to be,
    /// and waiting out the backoff or a ping would only leave the device unreachable longer.
    private func pathChanged(_ path: NWPath) {
        let now = (satisfied: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name))
        defer { lastPath = now }
        guard let last = lastPath, wantsConnection, now.satisfied else { return }
        if !last.satisfied || last.interfaces != now.interfaces { reconnectNow() }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(d): data = d
        @unknown default: return
        }
        guard let incoming = try? JSONDecoder().decode(Incoming.self, from: data) else { return }
        switch incoming {
        case let .challenge(nonce):
            let message = Data("macbridge-auth-v1|\(identity.deviceID)|\(nonce)".utf8)
            write(.auth(signature: identity.sign(message)), on: task)
        case .welcome:
            attempt = 0
            set(.online)
            schedulePing(task)
        case let .signal(from, envelope):
            DispatchQueue.main.async { self.onSignal?(from, envelope) }
        case let .ice(servers):
            flushIceWaiters(with: servers)
        case let .pair(from, sealed):
            DispatchQueue.main.async { self.onPairRequest?(from, sealed) }
        case let .pairReply(from, sealed):
            DispatchQueue.main.async { self.onPairReply?(from, sealed) }
        case let .presence(online):
            presenceStrikes = 0
            guard !presenceWaiters.isEmpty else { return }
            presenceWaiters.removeFirst()(Set(online))
        case let .error(error):
            if error == .unsupported("presence") {
                presenceUnsupported = true
                return flushPresenceWaiters()
            }
            if error == .other("bad-message"), !presenceWaiters.isEmpty {
                // The server closes the connection after this. It may be an old server that
                // does not know presence, or another message it did not like: off only on a repeat.
                presenceStrikes += 1
                if presenceStrikes >= 2 { presenceUnsupported = true }
                flushPresenceWaiters()
                return
            }
            // The server does not know some other message and stays connected: nothing to show.
            if case .unsupported = error { return }
            if case .unauthorized = error { stop() }
            DispatchQueue.main.async { self.onError?(error) }
        }
    }

    private func flushIceWaiters(with servers: [IceServer] = []) {
        let waiters = iceWaiters
        iceWaiters.removeAll()
        waiters.forEach { $0(servers) }
    }

    private func flushPresenceWaiters() {
        let waiters = presenceWaiters
        presenceWaiters.removeAll()
        waiters.forEach { $0(nil) }
    }

    /// Sends once logged in; dropped otherwise.
    private func write(_ message: Outgoing) {
        queue.async {
            guard let task = self.task, self.status == .online else { return }
            self.write(message, on: task)
        }
    }

    private func write(_ message: Outgoing, on task: URLSessionWebSocketTask) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let self, error != nil else { return }
            self.queue.async { self.dropped(task) }
        }
    }

    private func set(_ new: Status) {
        guard new != status else { return }
        status = new
        DispatchQueue.main.async { self.onStatus?(new) }
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        queue.async {
            // The receive may have failed first and dropped the task already; the code still counts
            // while no newer connection has opened.
            if closeCode.rawValue == Self.replacedCloseCode, self.wantsConnection,
               self.task == nil, webSocketTask === self.droppedTask {
                return self.replaced()
            }
            self.dropped(webSocketTask, closeCode: closeCode.rawValue)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let socket = task as? URLSessionWebSocketTask else { return }
        queue.async { self.dropped(socket) }
    }
}

// MARK: - Wire messages

private struct Sealed: Codable {
    var sealed: Data
}

private enum Outgoing: Encodable {
    case hello(id: String, key: Data, token: String?)
    case auth(signature: Data)
    case signal(to: String, data: SignalEnvelope)
    case ice
    case presence(ids: [String])
    case pairOpen(tag: String)
    case pairClose
    case pair(tag: String, sealed: Data)
    case pairReply(to: String, sealed: Data)

    private enum CodingKeys: String, CodingKey { case type, id, key, token, sig, to, data, tag, ids }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(id, key, token):
            try c.encode("hello", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(key, forKey: .key)
            try c.encodeIfPresent(token, forKey: .token)
        case let .auth(signature):
            try c.encode("auth", forKey: .type)
            try c.encode(signature, forKey: .sig)
        case let .signal(to, data):
            try c.encode("signal", forKey: .type)
            try c.encode(to, forKey: .to)
            try c.encode(data, forKey: .data)
        case .ice:
            try c.encode("ice", forKey: .type)
        case let .presence(ids):
            try c.encode("presence", forKey: .type)
            try c.encode(ids, forKey: .ids)
        case let .pairOpen(tag):
            try c.encode("pair-open", forKey: .type)
            try c.encode(tag, forKey: .tag)
        case .pairClose:
            try c.encode("pair-close", forKey: .type)
        case let .pair(tag, sealed):
            try c.encode("pair", forKey: .type)
            try c.encode(tag, forKey: .tag)
            try c.encode(Sealed(sealed: sealed), forKey: .data)
        case let .pairReply(to, sealed):
            try c.encode("pair-reply", forKey: .type)
            try c.encode(to, forKey: .to)
            try c.encode(Sealed(sealed: sealed), forKey: .data)
        }
    }
}

private enum Incoming: Decodable {
    case challenge(nonce: String)
    case welcome
    case signal(from: String, SignalEnvelope)
    case ice([IceServer])
    case presence(online: [String])
    case pair(from: String, sealed: Data)
    case pairReply(from: String, sealed: Data)
    case error(SignalingClient.ServerError)

    private enum CodingKeys: String, CodingKey { case type, nonce, from, data, servers, code, to, online, messageType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "challenge":
            self = .challenge(nonce: try c.decode(String.self, forKey: .nonce))
        case "welcome":
            self = .welcome
        case "signal":
            self = .signal(
                from: try c.decode(String.self, forKey: .from),
                try c.decode(SignalEnvelope.self, forKey: .data)
            )
        case "ice":
            self = .ice(try c.decode([IceServer].self, forKey: .servers))
        case "presence":
            self = .presence(online: try c.decode([String].self, forKey: .online))
        case "pair":
            self = .pair(
                from: try c.decode(String.self, forKey: .from),
                sealed: try c.decode(Sealed.self, forKey: .data).sealed
            )
        case "pair-reply":
            self = .pairReply(
                from: try c.decode(String.self, forKey: .from),
                sealed: try c.decode(Sealed.self, forKey: .data).sealed
            )
        case "error":
            let code = try c.decode(String.self, forKey: .code)
            switch code {
            case "offline":
                self = .error(.peerOffline(try c.decodeIfPresent(String.self, forKey: .to) ?? ""))
            case "no-such-pairing":
                self = .error(.noSuchPairing)
            case "bad-token", "bad-auth", "bad-id":
                self = .error(.unauthorized(code))
            case "unsupported":
                self = .error(.unsupported(try c.decodeIfPresent(String.self, forKey: .messageType) ?? ""))
            default:
                self = .error(.other(code))
            }
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown message type \(other)")
        }
    }
}
