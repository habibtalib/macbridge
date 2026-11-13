import Foundation

/// WebSocket connection to the signaling server. Stays connected: if the socket
/// drops it reconnects with backoff until `disconnect()` is called.
///
/// Callbacks are delivered on the main queue.
public final class SignalingClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case offline
        case connecting
        case online
    }

    public enum ServerError: Equatable, Sendable {
        /// The device a signal was addressed to is not connected.
        case peerOffline(String)
        case other(String)
    }

    public var onStatus: ((Status) -> Void)?
    public var onSignal: ((_ from: String, SignalPayload) -> Void)?
    public var onError: ((ServerError) -> Void)?

    private let url: URL
    private let deviceID: String
    private let queue = DispatchQueue(label: "macbridge.signaling")
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    // Guarded by `queue`.
    private var task: URLSessionWebSocketTask?
    private var wantsConnection = false
    private var attempt = 0
    private var status: Status = .offline

    public init(url: URL, deviceID: String) {
        self.url = url
        self.deviceID = deviceID
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
        queue.async {
            self.wantsConnection = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.set(.offline)
        }
    }

    public func send(_ payload: SignalPayload, to peer: String) {
        queue.async {
            guard let task = self.task, self.status == .online else { return }
            self.write(Outgoing.signal(to: peer, data: payload), on: task)
        }
    }

    // MARK: - Connection

    private func open() {
        set(.connecting)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 256 * 1024
        self.task = task
        task.resume()
        write(Outgoing.hello(id: deviceID), on: task)
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard task === self.task else { return }
                switch result {
                case let .success(message):
                    self.handle(message)
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
        guard wantsConnection else { return set(.offline) }
        set(.connecting)
        attempt += 1
        let delay = min(30, pow(2, Double(attempt - 1)))
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.wantsConnection, self.task == nil else { return }
            self.open()
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(d): data = d
        @unknown default: return
        }
        guard let incoming = try? JSONDecoder().decode(Incoming.self, from: data) else { return }
        switch incoming {
        case .welcome:
            attempt = 0
            set(.online)
        case let .signal(from, payload):
            DispatchQueue.main.async { self.onSignal?(from, payload) }
        case let .error(error):
            DispatchQueue.main.async { self.onError?(error) }
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

private enum Outgoing: Encodable {
    case hello(id: String)
    case signal(to: String, data: SignalPayload)

    private enum CodingKeys: String, CodingKey { case type, id, to, data }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(id):
            try c.encode("hello", forKey: .type)
            try c.encode(id, forKey: .id)
        case let .signal(to, data):
            try c.encode("signal", forKey: .type)
            try c.encode(to, forKey: .to)
            try c.encode(data, forKey: .data)
        }
    }
}

private enum Incoming: Decodable {
    case welcome
    case signal(from: String, SignalPayload)
    case error(SignalingClient.ServerError)

    private enum CodingKeys: String, CodingKey { case type, from, data, code, to }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "welcome":
            self = .welcome
        case "signal":
            self = .signal(
                from: try c.decode(String.self, forKey: .from),
                try c.decode(SignalPayload.self, forKey: .data)
            )
        case "error":
            let code = try c.decode(String.self, forKey: .code)
            if code == "offline", let to = try c.decodeIfPresent(String.self, forKey: .to) {
                self = .error(.peerOffline(to))
            } else {
                self = .error(.other(code))
            }
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown message type \(other)")
        }
    }
}
