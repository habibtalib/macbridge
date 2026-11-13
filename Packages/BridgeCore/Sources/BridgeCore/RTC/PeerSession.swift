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

        public init(maxBitrateBps: Int = 20_000_000, maxFramerate: Int = 60) {
            self.maxBitrateBps = maxBitrateBps
            self.maxFramerate = maxFramerate
        }
    }

    public let role: Role
    public var onSignal: ((SignalPayload) -> Void)?
    public var onState: ((PeerState) -> Void)?
    /// Host only: input received from the controller.
    public var onInput: ((InputMessage) -> Void)?
    /// Controller only: the host's screen.
    public var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
    /// Controller only: both input channels are open and `send` will go through.
    public var onInputReady: (() -> Void)?

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

            let fast = RTCDataChannelConfiguration()
            fast.isOrdered = false
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

    /// Controller: send input to the host. Returns false if the channel is not open.
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

    // MARK: - Internals

    private static var noConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    private func setRemote(_ description: RTCSessionDescription, then next: @escaping () -> Void) {
        connection.setRemoteDescription(description) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard error == nil, !self.isClosed else { return self.fail() }
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
        reliableChannel?.close()
        fastChannel?.close()
        remoteVideoTrack = nil
        connection.close()
        onState?(.closed)
    }
}

extension PeerSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onSignal?(.candidate(sdp: candidate.sdp, mLineIndex: candidate.sdpMLineIndex, mid: candidate.sdpMid))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
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
        // Controller side: these are the channels the host opened.
        queue.async {
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
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

extension PeerSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard role == .controller else { return }
        queue.async { self.reportInputReadyIfOpen() }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // Only the host acts on input, and only well-formed messages.
        guard role == .host, let message = try? InputMessage(decoding: buffer.data) else { return }
        onInput?(message)
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
        let encoder = RTCDefaultVideoEncoderFactory()
        // H.264 is the codec with hardware encode and decode on every Mac.
        if let h264 = encoder.supportedCodecs().first(where: { $0.name == kRTCVideoCodecH264Name }) {
            encoder.preferredCodec = h264
        }
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
}
