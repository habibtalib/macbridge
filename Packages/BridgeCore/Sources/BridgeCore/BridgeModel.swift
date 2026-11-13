import Combine
import Foundation

/// The app's state: the signaling connection plus, at most, one session where
/// this Mac is being controlled and one where it is controlling another Mac.
@MainActor
public final class BridgeModel: ObservableObject {
    public enum ControllerStatus: Equatable {
        case idle
        case calling(String)
        case connected(String)
        case failed(String)
    }

    public enum HostStatus: Equatable {
        case idle
        case sharing(to: String)
    }

    // Settings, saved as they change.
    @Published public var serverURL: String { didSet { defaults.set(serverURL, forKey: Keys.serverURL) } }
    @Published public var deviceName: String { didSet { defaults.set(deviceName, forKey: Keys.deviceName) } }
    @Published public var allowsControl: Bool {
        didSet {
            defaults.set(allowsControl, forKey: Keys.allowsControl)
            if !allowsControl { endHosting(notify: true) }
        }
    }

    @Published public private(set) var signalingStatus: SignalingClient.Status = .offline
    @Published public private(set) var controllerStatus: ControllerStatus = .idle
    @Published public private(set) var hostStatus: HostStatus = .idle
    @Published public private(set) var remoteVideo: RemoteVideo?
    @Published public private(set) var remoteVideoSize: CGSize?
    @Published public private(set) var notice: String?
    @Published public private(set) var hasScreenPermission = ScreenCapturer.hasPermission
    @Published public private(set) var hasInputPermission = InputInjector.hasPermission

    private let defaults: UserDefaults
    private var signaling: SignalingClient?

    private var controllerSession: PeerSession?
    private var controllerPeer: String?

    private var hostSession: PeerSession?
    private var hostPeer: String?
    private var injector: InputInjector?
    private let capturer = ScreenCapturer()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Self.defaultDeviceName()
        allowsControl = defaults.bool(forKey: Keys.allowsControl)
        capturer.onStop = { [weak self] _ in
            Task { @MainActor in self?.endHosting(notify: true) }
        }
    }

    public var isDeviceNameValid: Bool { Self.isValidDeviceName(deviceName) }
    public var parsedServerURL: URL? { Self.parseServerURL(serverURL) }
    public var canGoOnline: Bool { isDeviceNameValid && parsedServerURL != nil }

    // MARK: - Signaling

    /// Connects to the signaling server with the current settings, replacing
    /// any existing connection.
    public func goOnline() {
        goOffline()
        guard let url = parsedServerURL, isDeviceNameValid else { return }
        let client = SignalingClient(url: url, deviceID: deviceName)
        client.onStatus = { [weak self] status in self?.signalingStatus = status }
        client.onSignal = { [weak self] from, payload in self?.receive(payload, from: from) }
        client.onError = { [weak self] error in self?.receive(error) }
        signaling = client
        client.connect()
    }

    public func goOffline() {
        disconnect()
        endHosting(notify: true)
        signaling?.disconnect()
        signaling = nil
        signalingStatus = .offline
    }

    private func receive(_ payload: SignalPayload, from peer: String) {
        if peer == controllerPeer, payload != .request {
            if payload == .bye {
                endControlling(.failed("\(peer) ended the session"))
            } else {
                controllerSession?.handle(payload)
            }
            return
        }
        switch payload {
        case .request:
            Task { await beginHosting(for: peer) }
        case .bye:
            if peer == hostPeer { endHosting(notify: false) }
        case .answer, .candidate:
            if peer == hostPeer { hostSession?.handle(payload) }
        case .offer:
            break // an offer nobody asked for
        }
    }

    private func receive(_ error: SignalingClient.ServerError) {
        switch error {
        case let .peerOffline(peer):
            if peer == controllerPeer { endControlling(.failed("\(peer) is offline")) }
            if peer == hostPeer { endHosting(notify: false) }
        case let .other(code):
            notice = "Server error: \(code)"
        }
    }

    // MARK: - Controlling another Mac

    public func connect(to host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard signalingStatus == .online, Self.isValidDeviceName(host), host != deviceName else { return }
        disconnect()
        guard let session = PeerSession(role: .controller) else {
            controllerStatus = .failed("Could not start a session")
            return
        }
        controllerSession = session
        controllerPeer = host
        controllerStatus = .calling(host)

        session.onSignal = { [weak self] payload in
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                self.signaling?.send(payload, to: host)
            }
        }
        session.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                self.remoteVideo = RemoteVideo(track: track)
            }
        }
        session.onState = { [weak self] state in
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                switch state {
                case .connected: self.controllerStatus = .connected(host)
                case .failed: self.endControlling(.failed("Connection to \(host) failed"))
                case .closed: self.endControlling(.idle)
                case .connecting, .disconnected: break
                }
            }
        }
        signaling?.send(.request, to: host)
    }

    public func disconnect() {
        guard controllerSession != nil else { return }
        if let controllerPeer { signaling?.send(.bye, to: controllerPeer) }
        endControlling(.idle)
    }

    /// Sends input to the host being controlled.
    public func sendInput(_ message: InputMessage) {
        controllerSession?.send(message)
    }

    public func setRemoteVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        remoteVideoSize = size
    }

    private func endControlling(_ status: ControllerStatus) {
        let session = controllerSession
        controllerSession = nil
        controllerPeer = nil
        remoteVideo = nil
        remoteVideoSize = nil
        controllerStatus = status
        session?.close()
    }

    // MARK: - Being controlled

    private func beginHosting(for peer: String) async {
        guard allowsControl else {
            signaling?.send(.bye, to: peer)
            return
        }
        refreshPermissions()
        guard hasScreenPermission else {
            notice = "\(peer) tried to connect, but Screen Recording is not allowed for MacBridge."
            signaling?.send(.bye, to: peer)
            return
        }
        // One controller at a time: a new request replaces the current session.
        endHosting(notify: true)
        guard let session = PeerSession(role: .host) else { return }
        hostSession = session
        hostPeer = peer

        session.onSignal = { [weak self] payload in
            Task { @MainActor in
                guard let self, self.hostSession === session else { return }
                self.signaling?.send(payload, to: peer)
            }
        }
        session.onState = { [weak self] state in
            Task { @MainActor in
                guard let self, self.hostSession === session else { return }
                switch state {
                case .connected: self.hostStatus = .sharing(to: peer)
                case .failed, .closed: self.endHosting(notify: false)
                case .connecting, .disconnected: break
                }
            }
        }

        do {
            let display = try await capturer.start()
            guard hostSession === session else { return } // replaced while starting
            let injector = InputInjector(display: display)
            self.injector = injector
            session.onInput = { injector.handle($0) }
            capturer.onFrame = { [weak session] buffer, timestampNs in
                session?.push(buffer, timestampNs: timestampNs)
            }
            session.start()
            notice = hasInputPermission ? nil : "\(peer) can see this screen but not control it: Accessibility is not allowed for MacBridge."
        } catch {
            notice = "Could not capture the screen: \(error.localizedDescription)"
            signaling?.send(.bye, to: peer)
            endHosting(notify: false)
        }
    }

    private func endHosting(notify: Bool) {
        guard let session = hostSession else { return }
        if notify, let hostPeer { signaling?.send(.bye, to: hostPeer) }
        hostSession = nil
        hostPeer = nil
        hostStatus = .idle
        capturer.onFrame = nil
        injector?.releaseAll()
        injector = nil
        session.close()
        Task { await capturer.stop() }
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        hasScreenPermission = ScreenCapturer.hasPermission
        hasInputPermission = InputInjector.hasPermission
    }

    public func requestScreenPermission() {
        ScreenCapturer.requestPermission()
        refreshPermissions()
    }

    public func requestInputPermission() {
        InputInjector.requestPermission()
        refreshPermissions()
    }

    public func dismissNotice() { notice = nil }

    // MARK: - Validation

    private enum Keys {
        static let serverURL = "serverURL"
        static let deviceName = "deviceName"
        static let allowsControl = "allowsControl"
    }

    /// Same rule the server enforces.
    nonisolated public static func isValidDeviceName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count) && name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }

    nonisolated public static func parseServerURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The computer's name reduced to the characters a device name allows.
    nonisolated public static func defaultDeviceName(from hostName: String? = Host.current().localizedName) -> String {
        let cleaned = (hostName ?? "")
            .folding(options: [.diacriticInsensitive], locale: nil)
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let name = String(cleaned.prefix(64))
        return name.isEmpty ? "mac" : name
    }
}
