import CoreVideo
import Foundation
import WebRTC

public struct IceServer: Equatable, Sendable, Codable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public enum PeerState: Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

/// One WebRTC connection between a host and a controller.
///
/// The host offers: it owns the video track and opens the two input channels.
/// The controller answers, renders the track and sends input.
///
/// Signaling is left to the caller: forward `onSignal` payloads to the other
/// side and feed what comes back into `handle(_:)`.
/// Callbacks arrive on WebRTC's threads; hop to the main queue before touching UI.
public final class PeerSession: NSObject, @unchecked Sendable {
    public enum Role: Sendable { case host, controller }

    public struct VideoSettings: Sendable {
        public var maxBitrateBps: Int
        public var maxFramerate: Int

        public init(maxBitrateBps: Int = 30_000_000, maxFramerate: Int = 60) {
            self.maxBitrateBps = maxBitrateBps
            self.maxFramerate = maxFramerate
        }
    }

    public let role: Role
    public var onSignal: ((SignalPayload) -> Void)? {
        get { callbacks.read { $0.onSignal } }
        set { setCallback { $0.onSignal = newValue } }
    }
    public var onState: ((PeerState) -> Void)? {
        get { callbacks.read { $0.onState } }
        set { setCallback { $0.onState = newValue } }
    }
    /// Host only: input received from the controller.
    public var onInput: ((InputMessage) -> Void)? {
        get { callbacks.read { $0.onInput } }
        set { setCallback { $0.onInput = newValue } }
    }
    /// Controller only: the host's screen.
    public var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)? {
        get { callbacks.read { $0.onRemoteVideoTrack } }
        set { setCallback { $0.onRemoteVideoTrack = newValue } }
    }
    /// Controller only: both input channels are open and `send` will go through.
    public var onInputReady: (() -> Void)? {
        get { callbacks.read { $0.onInputReady } }
        set { setCallback { $0.onInputReady = newValue } }
    }
    /// Controller: text was copied on the host.
    public var onClipboard: ((String) -> Void)? {
        get { callbacks.read { $0.onClipboard } }
        set { setCallback { $0.onClipboard = newValue } }
    }
    /// Controller: the host's displays, sent when the session starts and when the shown display changes.
    public var onDisplays: (([RemoteDisplay]) -> Void)? {
        get { callbacks.read { $0.onDisplays } }
        set { setCallback { $0.onDisplays = newValue } }
    }

    /// The callbacks are set on the main thread and called on WebRTC's threads:
    /// a lock, not `queue`, which `send` holds while it calls into WebRTC.
    /// Cleared on close, which also breaks any cycle through a callback that
    /// holds this session.
    private struct Callbacks {
        var isClosed = false
        var onSignal: ((SignalPayload) -> Void)?
        var onState: ((PeerState) -> Void)?
        var onInput: ((InputMessage) -> Void)?
        var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
        var onInputReady: (() -> Void)?
        var onClipboard: ((String) -> Void)?
        var onDisplays: (([RemoteDisplay]) -> Void)?
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func read<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
        func write(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
    }

    private let callbacks = Locked(Callbacks())

    /// A callback set after close is dropped, so it cannot keep anything alive.
    private func setCallback(_ body: (inout Callbacks) -> Void) {
        callbacks.write { if !$0.isClosed { body(&$0) } }
    }

    private static let reliableLabel = "input-reliable"
    private static let fastLabel = "input-fast"

    private let queue = DispatchQueue(label: "macbridge.peer")
    private let connection: RTCPeerConnection
    private let videoSettings: VideoSettings

    // Host only.
    private let videoSource: RTCVideoSource?
    private let capturer: RTCVideoCapturer?

    // Guarded by `queue`.
    private var reliableChannel: RTCDataChannel?
    private var fastChannel: RTCDataChannel?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var isClosed = false
    /// Held for the life of the session: WebRTC detaches a track's renderers
    /// when the Swift wrapper is released.
    private var remoteVideoTrack: RTCVideoTrack?

    public init?(role: Role, iceServers: [IceServer] = [], relayOnly: Bool = false, video: VideoSettings = .init()) {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = relayOnly ? .relay : .all
        config.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = RTCEngine.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            return nil
        }
        self.role = role
        self.connection = connection
        self.videoSettings = video
        if role == .host {
            let source = RTCEngine.factory.videoSource(forScreenCast: true)
            videoSource = source
            capturer = RTCVideoCapturer(delegate: source)
        } else {
            videoSource = nil
            capturer = nil
        }
        super.init()
        connection.delegate = self
        // Start well above WebRTC's ~300 kbit/s default so the first seconds of a
        // session are not a blur; congestion control still backs off if needed.
        connection.setBweMinBitrateBps(
            NSNumber(value: 1_000_000),
            currentBitrateBps: NSNumber(value: min(8_000_000, video.maxBitrateBps)),
            maxBitrateBps: NSNumber(value: video.maxBitrateBps))
    }

    /// Host: add the screen track and input channels, then send the offer.
    public func start() {
        precondition(role == .host, "only the host starts a session")
        queue.async {
            guard !self.isClosed, let source = self.videoSource else { return }

            let track = RTCEngine.factory.videoTrack(with: source, trackId: "screen")
            if let sender = self.connection.add(track, streamIds: ["screen"]) {
                self.apply(self.videoSettings, to: sender)
            }

            let reliable = RTCDataChannelConfiguration()
            reliable.isOrdered = true
            self.reliableChannel = self.connection.dataChannel(forLabel: Self.reliableLabel, configuration: reliable)
            self.reliableChannel?.delegate = self

            // Pointer moves: never resent, so a lost one is skipped, but kept in
            // order, so an old position cannot land after a newer one.
            let fast = RTCDataChannelConfiguration()
            fast.isOrdered = true
            fast.maxRetransmits = 0
            self.fastChannel = self.connection.dataChannel(forLabel: Self.fastLabel, configuration: fast)
            self.fastChannel?.delegate = self

            self.connection.offer(for: Self.noConstraints) { description, _ in
                guard let description else { return self.fail() }
                self.connection.setLocalDescription(description) { error in
                    guard error == nil else { return self.fail() }
                    self.onSignal?(.offer(sdp: description.sdp))
                }
            }
        }
    }

    /// Feed a signal that arrived from the other side.
    public func handle(_ signal: SignalPayload) {
        Self.writeStats("signal in: \(Self.kind(signal)) (\(role))")
        queue.async {
            guard !self.isClosed else { return }
            switch signal {
            case .request:
                break
            case let .offer(sdp):
                guard self.role == .controller else { return }
                self.setRemote(RTCSessionDescription(type: .offer, sdp: sdp)) {
                    self.connection.answer(for: Self.noConstraints) { description, _ in
                        guard let description else { return self.fail() }
                        self.connection.setLocalDescription(description) { error in
                            guard error == nil else { return self.fail() }
                            self.onSignal?(.answer(sdp: description.sdp))
                        }
                    }
                }
            case let .answer(sdp):
                guard self.role == .host else { return }
                self.setRemote(RTCSessionDescription(type: .answer, sdp: sdp)) {}
            case let .candidate(sdp, mLineIndex, mid):
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLineIndex, sdpMid: mid)
                if self.hasRemoteDescription {
                    self.connection.add(candidate) { _ in }
                } else {
                    self.pendingCandidates.append(candidate)
                }
            case .bye:
                self.closeLocked()
            }
        }
    }

    /// Host: push one captured frame into the video track.
    public func push(_ pixelBuffer: CVPixelBuffer, timestampNs: Int64) {
        guard let videoSource, let capturer else { return }
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: timestampNs
        )
        videoSource.capturer(capturer, didCapture: frame)
    }

    /// Controller: send input to the host. Host: send its clipboard (`.clipboard`) to the controller.
    /// Returns false if the channel is not open.
    @discardableResult
    public func send(_ message: InputMessage) -> Bool {
        queue.sync {
            let channel = message.prefersUnreliableChannel ? fastChannel : reliableChannel
            guard let channel, channel.readyState == .open else { return false }
            return channel.sendData(RTCDataBuffer(data: message.encoded(), isBinary: true))
        }
    }

    public func close() {
        queue.async { self.closeLocked() }
    }

    /// WebRTC's own counters for the video stream (`framesEncoded`,
    /// `framesDecoded`, `frameWidth`, `encoderImplementation`, ...), one entry
    /// per `outbound-rtp` / `inbound-rtp` stat.
    public func videoStats(_ completion: @escaping ([[String: String]]) -> Void) {
        connection.statistics { report in
            completion(
                report.statistics.values
                    .filter { $0.type == "outbound-rtp" || $0.type == "inbound-rtp" }
                    .map { $0.values.mapValues { "\($0)" } }
            )
        }
    }

    /// What the session window shows about the connection. Works on either side;
    /// the picture numbers are for the video this side receives (controller) or sends (host).
    public func sessionStats(_ completion: @escaping (SessionStats) -> Void) {
        let role = role
        connection.statistics { report in
            completion(SessionStats(report.statistics.values.map { ($0.type, $0.id, $0.values) }, incoming: role == .controller))
        }
    }

    /// Writes the video and connection counters to the system log
    /// (`log stream --predicate 'eventMessage BEGINSWITH "MacBridgeStats"'`).
    public func logStats() {
        connection.statistics { report in
            Self.writeStats("report \(report.statistics.count) stats")
            let wanted: Set<String> = ["outbound-rtp", "inbound-rtp", "candidate-pair", "media-source"]
            let keys: Set<String> = [
                "kind", "framesEncoded", "framesSent", "framesDecoded", "framesReceived", "framesDropped",
                "bytesSent", "bytesReceived", "frameWidth", "frameHeight", "framesPerSecond",
                "encoderImplementation", "qualityLimitationReason", "keyFramesEncoded", "keyFramesDecoded",
                "pliCount", "nackCount", "frames", "width", "height",
                "state", "nominated", "currentRoundTripTime", "availableOutgoingBitrate",
                "localCandidateId", "remoteCandidateId", "packetsLost",
            ]
            // Type and protocol only: addresses stay out of the log.
            var candidates: [String: String] = [:]
            for stat in report.statistics.values where stat.type == "local-candidate" || stat.type == "remote-candidate" {
                candidates[stat.id] = [stat.values["candidateType"], stat.values["protocol"]].map { $0.map { "\($0)" } ?? "?" }.joined(separator: "/")
            }
            for stat in report.statistics.values where wanted.contains(stat.type) {
                if stat.type == "candidate-pair", (stat.values["nominated"] as? NSNumber)?.boolValue != true { continue }
                var fields = stat.values.filter { keys.contains($0.key) }.map { "\($0.key)=\($0.value)" }.sorted()
                if let l = stat.values["localCandidateId"] { fields.append("local=\(candidates["\(l)"] ?? "?")") }
                if let r = stat.values["remoteCandidateId"] { fields.append("remote=\(candidates["\(r)"] ?? "?")") }
                Self.writeStats("\(stat.type) \(fields.joined(separator: " "))")
            }
        }
    }

    static func kind(_ signal: SignalPayload) -> String {
        switch signal {
        case .request: "request"
        case .offer: "offer"
        case .answer: "answer"
        case let .candidate(sdp, _, _): "candidate \(candidateType(sdp))"
        case .bye: "bye"
        }
    }

    /// A candidate's type ("host", "srflx", "relay"), the part of it worth logging:
    /// the rest holds IP addresses.
    static func candidateType(_ sdp: String) -> String {
        let words = sdp.split(separator: " ")
        guard let index = words.firstIndex(of: "typ"), index + 1 < words.count else { return "?" }
        return String(words[index + 1])
    }

    private static let statsQueue = DispatchQueue(label: "macbridge.stats-log", qos: .utility)
    /// Used only on `statsQueue`: the formatter is not thread-safe.
    nonisolated(unsafe) private static let statsDateFormatter = ISO8601DateFormatter()
    static let statsLogLimit = 5 * 1024 * 1024

    static var statsLogURL: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacBridge-stats.log")
        #else
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacBridge-stats.log")
        #endif
    }

    /// Appends one line to ~/Library/Logs/MacBridge-stats.log, from any thread.
    public static func writeStats(_ line: String) {
        let date = Date()
        statsQueue.async {
            appendLine("\(statsDateFormatter.string(from: date)) \(line)\n", to: statsLogURL, limit: statsLogLimit)
        }
    }

    /// Appends to the log. A log at `limit` bytes or more is first moved to
    /// "<name>.1" (replacing the one there), so at most two are kept.
    static func appendLine(_ text: String, to url: URL, limit: Int) {
        let data = Data(text.utf8)
        let files = FileManager.default
        if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= limit {
            let old = url.appendingPathExtension("1")
            try? files.removeItem(at: old)
            try? files.moveItem(at: url, to: old)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            try? data.write(to: url)
        }
    }

    // MARK: - Internals

    private static var noConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    private func setRemote(_ description: RTCSessionDescription, then next: @escaping () -> Void) {
        connection.setRemoteDescription(description) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error { Self.writeStats("setRemote failed: \(error.localizedDescription)") }
                guard error == nil, !self.isClosed else { return self.fail() }
                Self.writeStats("remote description set, \(self.pendingCandidates.count) queued candidates")
                self.hasRemoteDescription = true
                self.pendingCandidates.forEach { self.connection.add($0) { _ in } }
                self.pendingCandidates.removeAll()
                next()
            }
        }
    }

    /// Screen content: keep text sharp and let the frame rate drop under pressure.
    private func apply(_ settings: VideoSettings, to sender: RTCRtpSender) {
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: settings.maxBitrateBps)
            encoding.maxFramerate = NSNumber(value: settings.maxFramerate)
        }
        sender.parameters = parameters
    }

    private func fail() {
        onState?(.failed)
    }

    private func closeLocked() {
        guard !isClosed else { return }
        isClosed = true
        let onState = callbacks.read { $0.onState }
        // From here on nothing more is delivered: input arriving after close
        // must not reach an injector that has already let go of every key.
        callbacks.write { $0 = Callbacks(isClosed: true) }
        reliableChannel?.close()
        fastChannel?.close()
        remoteVideoTrack = nil
        connection.close()
        onState?(.closed)
    }
}

extension PeerSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Self.writeStats("local candidate: \(Self.candidateType(candidate.sdp))")
        onSignal?(.candidate(sdp: candidate.sdp, mLineIndex: candidate.sdpMLineIndex, mid: candidate.sdpMid))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Self.writeStats("connection state: \(newState.rawValue)")
        switch newState {
        case .new, .connecting: onState?(.connecting)
        case .connected: onState?(.connected)
        case .disconnected: onState?(.disconnected)
        case .failed: onState?(.failed)
        case .closed: break // reported once by closeLocked()
        @unknown default: break
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]
    ) {
        guard role == .controller, let track = rtpReceiver.track as? RTCVideoTrack else { return }
        queue.async {
            guard !self.isClosed else { return }
            self.remoteVideoTrack = track
            self.onRemoteVideoTrack?(track)
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Controller side: these are the channels the host opened. The host takes input only on
        // the channels it created itself: one the controller opens gets no delegate, so nothing
        // it carries is read, and it cannot replace the host's own.
        guard role == .controller else { return }
        queue.async {
            guard !self.isClosed else { return }
            switch dataChannel.label {
            case Self.reliableLabel: self.reliableChannel = dataChannel
            case Self.fastLabel: self.fastChannel = dataChannel
            default: return
            }
            dataChannel.delegate = self
            self.reportInputReadyIfOpen()
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Self.writeStats("ice state: \(newState.rawValue)")
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

extension PeerSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        queue.async { self.reportInputReadyIfOpen() }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // Only well-formed messages. The host acts on input; the controller
        // accepts nothing from the host but copied text.
        guard let message = try? InputMessage(decoding: buffer.data),
              !callbacks.read({ $0.isClosed }) else { return }
        switch role {
        case .host: onInput?(message)
        case .controller:
            switch message {
            case let .clipboard(text): onClipboard?(text)
            case let .displays(list): onDisplays?(list)
            default: break
            }
        }
    }

    private func reportInputReadyIfOpen() {
        guard reliableChannel?.readyState == .open, fastChannel?.readyState == .open else { return }
        onInputReady?()
    }
}

/// One factory for the whole process; WebRTC's threads live inside it.
enum RTCEngine {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: ScreenCodecFactory(), decoderFactory: ScreenCodecFactory())
    }()
}

/// Offers exactly one codec: hardware H.264, High profile, level 5.2.
///
/// WebRTC's stock factory advertises H.264 at level 3.1, which tops out at
/// 720p. Given a Retina-sized screen it silently falls back to software VP8
/// and manages about one frame a second. Level 5.2 covers 4K at 60 fps, and
/// leaving the software codecs out means it can never fall back unnoticed.
final class ScreenCodecFactory: NSObject, RTCVideoEncoderFactory, RTCVideoDecoderFactory {
    static let codec = RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: [
        "profile-level-id": "640c34", // constrained High, level 5.2
        "level-asymmetry-allowed": "1",
        "packetization-mode": "1",
    ])

    func supportedCodecs() -> [RTCVideoCodecInfo] { [Self.codec] }

    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        info.name == kRTCVideoCodecH264Name ? RTCVideoEncoderH264(codecInfo: info) : nil
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        info.name == kRTCVideoCodecH264Name ? RTCVideoDecoderH264() : nil
    }
}

/// A snapshot of a session's connection, read from WebRTC's counters.
public struct SessionStats: Equatable, Sendable {
    public var width = 0
    public var height = 0
    public var framesPerSecond = 0.0
    /// Video bytes so far; two snapshots give the bit rate.
    public var videoBytes: Int64 = 0
    public var packetsLost = 0
    public var packets = 0
    /// Round trip between the two Macs, in milliseconds.
    public var roundTripMs: Double?
    /// The traffic goes through the relay server instead of straight between the Macs.
    public var isRelayed: Bool?
    /// "H264", and whether it is decoded or encoded in hardware.
    public var codec: String?
    public var usesHardware: Bool?
    /// Filled in by the caller from two snapshots.
    public var bitsPerSecond: Double?

    public init() {}

    public var lossPercent: Double? {
        let total = packets + packetsLost
        return total > 0 ? Double(packetsLost) / Double(total) * 100 : nil
    }

    init(_ stats: [(type: String, id: String, values: [String: NSObject])], incoming: Bool) {
        func number(_ values: [String: NSObject], _ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
        func text(_ values: [String: NSObject], _ key: String) -> String? { values[key] as? String }
        var byID: [String: [String: NSObject]] = [:]
        for stat in stats { byID[stat.id] = stat.values }

        let rtp = incoming ? "inbound-rtp" : "outbound-rtp"
        if let video = stats.first(where: { $0.type == rtp && (text($0.values, "kind") ?? text($0.values, "mediaType")) == "video" })?.values {
            width = Int(number(video, "frameWidth") ?? 0)
            height = Int(number(video, "frameHeight") ?? 0)
            framesPerSecond = number(video, "framesPerSecond") ?? 0
            videoBytes = Int64(number(video, incoming ? "bytesReceived" : "bytesSent") ?? 0)
            packets = Int(number(video, incoming ? "packetsReceived" : "packetsSent") ?? 0)
            packetsLost = Int(number(video, "packetsLost") ?? 0)
            if let implementation = text(video, incoming ? "decoderImplementation" : "encoderImplementation") {
                usesHardware = implementation.contains("VideoToolbox")
            }
            if let codecID = text(video, "codecId"), let mime = byID[codecID].flatMap({ text($0, "mimeType") }) {
                codec = mime.replacingOccurrences(of: "video/", with: "")
            }
        }
        // The pair in use: the transport names it; older builds mark it "nominated".
        let selected = stats.first { $0.type == "transport" }.flatMap { text($0.values, "selectedCandidatePairId") }.flatMap { byID[$0] }
            ?? stats.first { $0.type == "candidate-pair" && (number($0.values, "nominated") ?? 0) != 0 && text($0.values, "state") == "succeeded" }?.values
        if let pair = selected {
            roundTripMs = number(pair, "currentRoundTripTime").map { $0 * 1000 }
            let types = ["localCandidateId", "remoteCandidateId"].compactMap { text(pair, $0) }.compactMap { byID[$0] }.compactMap { text($0, "candidateType") }
            if !types.isEmpty { isRelayed = types.contains("relay") }
        }
    }
}
