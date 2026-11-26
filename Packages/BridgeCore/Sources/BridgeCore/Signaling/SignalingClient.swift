import Foundation

/// A setup message plus, where required, the sender's proof of identity.
public struct SignalEnvelope: Equatable, Sendable, Codable {
    public var payload: SignalPayload
    public var auth: SignalAuth?

    public init(_ payload: SignalPayload, auth: SignalAuth? = nil) {
        self.payload = payload
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey { case auth }

    public init(from decoder: Decoder) throws {
        payload = try SignalPayload(from: decoder)
        auth = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(SignalAuth.self, forKey: .auth)
    }

    public func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(auth, forKey: .auth)
    }
}

/// WebSocket connection to the signaling server. Logs in by proving it holds
/// the identity key, then stays connected: if the socket drops it reconnects
/// with backoff until `disconnect()` is called.
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
        case other(String)
    }

    public var onStatus: ((Status) -> Void)?
    public var onSignal: ((_ from: String, SignalEnvelope) -> Void)?
    public var onError: ((ServerError) -> Void)?
    /// A device that typed our pairing code introduces itself.
    public var onPairRequest: ((_ from: String, _ sealed: Data) -> Void)?
    /// The device whose code we typed answers.
    public var onPairReply: ((_ from: String, _ sealed: Data) -> Void)?

    private let url: URL
    private let identity: Identity
    private let accessToken: String?
    private let queue = DispatchQueue(label: "macbridge.signaling")

    // Guarded by `queue`.
    /// Holds this client as its delegate until invalidated in `stop()`.
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var wantsConnection = false
    private var attempt = 0
    private var status: Status = .offline
    private var iceWaiters: [([IceServer]) -> Void] = []
    private var presenceWaiters: [(Set<String>?) -> Void] = []
    /// An older server closes the connection on a presence request: ask once, then never again.
    private var presenceUnsupported = false

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
            self.open()
        }
    }

    public func disconnect() {
        queue.async { self.stop() }
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
            self.presenceWaiters.append(finish)
            self.write(.presence(ids: Array(ids.prefix(64))), on: task)
            self.queue.asyncAfter(deadline: .now() + timeout) {
                self.presenceWaiters.removeAll()
                finish(nil)
            }
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
        task.resume()
        write(.hello(id: identity.deviceID, key: identity.publicKey, token: accessToken), on: task)
        receive(on: task)
    }

    private func stop() {
        wantsConnection = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // A URLSession keeps its delegate until invalidated: without this the
        // client, and the model it calls back, would never be freed.
        session?.invalidateAndCancel()
        session = nil
        flushIceWaiters()
        set(.offline)
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

    private func dropped(_ task: URLSessionWebSocketTask) {
        guard task === self.task else { return }
        self.task = nil
        task.cancel(with: .goingAway, reason: nil)
        flushIceWaiters()
        guard wantsConnection else { return set(.offline) }
        set(.connecting)
        attempt += 1
        let delay = min(30, pow(2, Double(attempt - 1)))
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.wantsConnection, self.task == nil else { return }
            self.open()
        }
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
        case let .signal(from, envelope):
            DispatchQueue.main.async { self.onSignal?(from, envelope) }
        case let .ice(servers):
            flushIceWaiters(with: servers)
        case let .pair(from, sealed):
            DispatchQueue.main.async { self.onPairRequest?(from, sealed) }
        case let .pairReply(from, sealed):
            DispatchQueue.main.async { self.onPairReply?(from, sealed) }
        case let .presence(online):
            let waiters = presenceWaiters
            presenceWaiters.removeAll()
            waiters.forEach { $0(Set(online)) }
        case let .error(error):
            let unsupported = error == .other("unsupported")
            if error == .other("bad-message") || unsupported, !presenceWaiters.isEmpty {
                // The server does not know the request. An older one closes the connection; the
                // reconnect that follows must not ask again.
                presenceUnsupported = true
                let waiters = presenceWaiters
                presenceWaiters.removeAll()
                waiters.forEach { $0(nil) }
                return
            }
            // A newer server says it does not know a message and stays connected: nothing to show.
            if unsupported { return }
            if case .unauthorized = error { stop() }
            DispatchQueue.main.async { self.onError?(error) }
        }
    }

    private func flushIceWaiters(with servers: [IceServer] = []) {
        let waiters = iceWaiters
        iceWaiters.removeAll()
        waiters.forEach { $0(servers) }
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
        queue.async { self.dropped(webSocketTask) }
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

    private enum CodingKeys: String, CodingKey { case type, nonce, from, data, servers, code, to, online }

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
            default:
                self = .error(.other(code))
            }
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown message type \(other)")
        }
    }
}
