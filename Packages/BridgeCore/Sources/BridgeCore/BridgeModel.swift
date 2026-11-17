import Combine
import CoreGraphics
import Foundation

/// The app's state: the signaling connection, the paired devices, and at most
/// one session where this Mac is being controlled and one where it is
/// controlling another Mac.
@MainActor
public final class BridgeModel: ObservableObject {
    public enum ControllerStatus: Equatable {
        case idle
        case calling(PairedDevice)
        case connected(PairedDevice)
        case failed(String)
    }

    public enum HostStatus: Equatable {
        case idle
        case sharing(to: PairedDevice)
    }

    public enum PairingStatus: Equatable {
        case idle
        /// This Mac is showing a code for another Mac to type.
        case showingCode(String, expires: Date)
        /// This Mac sent a typed code and is waiting for the other Mac.
        case waiting
        case failed(String)
    }

    // Settings, saved as they change.
    @Published public var serverURL: String { didSet { defaults.set(serverURL, forKey: Keys.serverURL) } }
    @Published public var accessToken: String { didSet { secrets.setAccessToken(accessToken) } }
    @Published public var deviceName: String { didSet { defaults.set(deviceName, forKey: Keys.deviceName) } }
    @Published public var forcesRelay: Bool { didSet { defaults.set(forcesRelay, forKey: Keys.forcesRelay) } }
    @Published public var allowsControl: Bool {
        didSet {
            defaults.set(allowsControl, forKey: Keys.allowsControl)
            if !allowsControl { endHosting(notify: true) }
            updatePower()
        }
    }

    @Published public private(set) var paired: [PairedDevice] = []
    @Published public private(set) var signalingStatus: SignalingClient.Status = .offline {
        didSet { updatePower() }
    }
    /// Who controlled this Mac and when, newest first.
    @Published public private(set) var sessionLog: [SessionLogEntry] = []
    @Published public private(set) var controllerStatus: ControllerStatus = .idle
    @Published public private(set) var hostStatus: HostStatus = .idle
    @Published public private(set) var pairingStatus: PairingStatus = .idle
    @Published public private(set) var remoteVideo: RemoteVideo?
    @Published public private(set) var remoteVideoSize: CGSize?
    @Published public private(set) var notice: String?
    @Published public private(set) var hasScreenPermission = ScreenCapturer.hasPermission
    @Published public private(set) var hasInputPermission = InputInjector.hasPermission

    public let identity: Identity
    public var deviceID: String { identity.deviceID }

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private var signaling: SignalingClient?

    private var controllerSession: PeerSession?
    private var controllerPeer: PairedDevice?
    private var controllerClipboard: ClipboardSync?
    private var hostClipboard: ClipboardSync?

    private var hostSession: PeerSession?
    private var hostPeer: PairedDevice?
    /// Ends a host session that stays disconnected; WebRTC may never report it as failed.
    private var hostDisconnectTimer: Task<Void, Never>?
    private var injector: InputInjector?
    private let capturer = ScreenCapturer()
    private let power = PowerAssertions()
    private var hostDisplay: DisplayInfo?
    /// Created for a session when this Mac has no usable screen (lid closed,
    /// no monitor); removed when the session ends.
    private var virtualDisplay: VirtualDisplay?
    private var hostQuality = QualityPreset.sharp
    private var currentLogEntry: UUID?
    /// Newest request accepted from each device, to refuse replays.
    private var lastRequest: [String: Int64] = [:]

    private var shownCode: PairingCode?
    private var typedCode: PairingCode?
    private var pairingTimeout: Task<Void, Never>?

    public init(identity: Identity, defaults: UserDefaults = .standard, secrets: SecretStore = .keychain) {
        self.identity = identity
        self.defaults = defaults
        self.secrets = secrets
        serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        accessToken = secrets.accessToken()
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Self.defaultDeviceName()
        forcesRelay = defaults.bool(forKey: Keys.forcesRelay)
        allowsControl = defaults.bool(forKey: Keys.allowsControl)
        paired = defaults.data(forKey: Keys.paired)
            .flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
        sessionLog = defaults.data(forKey: Keys.sessionLog)
            .flatMap { try? JSONDecoder().decode([SessionLogEntry].self, from: $0) } ?? []
        // Public, and handy for provisioning: scripts/link-remote.sh pairs two
        // Macs you already control by exchanging these over SSH.
        defaults.set(identity.publicKey.base64EncodedString(), forKey: Keys.publicKey)
        capturer.onStop = { [weak self] _ in
            Task { @MainActor in self?.endHosting(notify: true) }
        }
    }

    /// While this Mac accepts control and is meant to be online, it must not
    /// fall asleep, or it would drop off the server.
    private func updatePower() {
        power.keepSystemAwake = allowsControl && signaling != nil
    }

    public var parsedServerURL: URL? { Self.parseServerURL(serverURL) }
    public var canGoOnline: Bool { parsedServerURL != nil }
    /// Devices this Mac can control.
    public var controllable: [PairedDevice] { paired.filter(\.thisMacMayControl) }
    /// Devices that can control this Mac.
    public var controllers: [PairedDevice] { paired.filter(\.mayControlThisMac) }

    // MARK: - Signaling

    /// Connects to the signaling server with the current settings, replacing
    /// any existing connection.
    public func goOnline() {
        goOffline()
        guard let url = parsedServerURL else { return }
        let client = SignalingClient(url: url, identity: identity, accessToken: accessToken)
        client.onStatus = { [weak self] status in self?.signalingStatus = status }
        client.onSignal = { [weak self] from, envelope in self?.receive(envelope, from: from) }
        client.onError = { [weak self] error in self?.receive(error) }
        client.onPairRequest = { [weak self] from, sealed in self?.receivePairRequest(sealed, from: from) }
        client.onPairReply = { [weak self] from, sealed in self?.receivePairReply(sealed, from: from) }
        signaling = client
        client.connect()
        updatePower()
    }

    public func goOffline() {
        disconnect()
        endHosting(notify: true)
        cancelPairing()
        signaling?.disconnect()
        signaling = nil
        signalingStatus = .offline
        updatePower()
    }

    private func send(_ payload: SignalPayload, to peer: PairedDevice) {
        PeerSession.writeStats("signal out to \(peer.name): \(PeerSession.kind(payload)) (server \(signaling == nil ? "none" : "ok"))")
        let auth = SessionAuth.sign(payload, to: peer.id, identity: identity)
        signaling?.send(SignalEnvelope(payload, auth: auth), to: peer.id)
    }

    private func receive(_ envelope: SignalEnvelope, from peerID: String) {
        // Only paired devices get a hearing, and only with valid proof.
        guard let peer = paired.first(where: { $0.id == peerID }) else { return }
        let payload = envelope.payload
        let requestTimestamp: Int64?
        do {
            requestTimestamp = try SessionAuth.verify(
                payload, auth: envelope.auth, from: peer, to: deviceID, lastRequestTimestamp: lastRequest[peerID])
        } catch {
            PeerSession.writeStats("signal from \(peer.name) rejected: \(error) (\(PeerSession.kind(payload)))")
            return
        }
        if peer.id != hostPeer?.id, payload != .request {
            PeerSession.writeStats("signal from \(peer.name) ignored, no host session for it: \(PeerSession.kind(payload))")
        }

        if peer.id == controllerPeer?.id, peer.thisMacMayControl, payload != .request {
            if payload == .bye {
                endControlling(.failed("\(peer.name) ended the session"))
            } else {
                controllerSession?.handle(payload)
            }
            return
        }
        switch payload {
        case .request:
            guard peer.mayControlThisMac else { return }
            lastRequest[peerID] = requestTimestamp
            Task { await beginHosting(for: peer) }
        case .bye:
            if peer.id == hostPeer?.id { endHosting(notify: false) }
        case .answer, .candidate:
            if peer.id == hostPeer?.id { hostSession?.handle(payload) }
        case .offer:
            break // an offer nobody asked for
        }
    }

    private func receive(_ error: SignalingClient.ServerError) {
        switch error {
        case let .peerOffline(peerID):
            if peerID == controllerPeer?.id, let name = controllerPeer?.name {
                endControlling(.failed("\(name) is offline"))
            }
            if peerID == hostPeer?.id { endHosting(notify: false) }
            if typedCode != nil { failPairing("The other Mac went offline.") }
        case .noSuchPairing:
            failPairing("No Mac is showing that code. Check it and try again.")
        case let .unauthorized(code):
            signalingStatus = .offline
            notice = code == "bad-token"
                ? "The server refused the access token."
                : "The server refused this device (\(code))."
        case let .other(code):
            notice = "Server error: \(code)"
        }
    }

    private func iceServers() async -> [IceServer] {
        guard let signaling else { return [] }
        return await withCheckedContinuation { continuation in
            signaling.requestIceServers { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Pairing

    /// Shows a one-time code on this Mac. Whoever types it on another Mac
    /// running MacBridge gets the right to control this one.
    public func showPairingCode() {
        guard signalingStatus == .online else { return }
        cancelPairing()
        let code = PairingCode()
        shownCode = code
        signaling?.openPairing(tag: code.tag)
        pairingStatus = .showingCode(code.display, expires: Date().addingTimeInterval(PairingCode.lifetime))
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PairingCode.lifetime))
            guard !Task.isCancelled else { return }
            self?.cancelPairing()
        }
    }

    /// Sends a code typed on this Mac to the Mac that is showing it.
    public func pair(usingCode text: String) {
        guard signalingStatus == .online else { return }
        cancelPairing()
        guard let code = PairingCode(text) else {
            pairingStatus = .failed("That is not a valid code. It has 16 letters and digits.")
            return
        }
        let introduction = PairingCode.Introduction(publicKey: identity.publicKey, name: deviceName)
        guard let sealed = code.seal(introduction, from: .controller) else { return }
        typedCode = code
        pairingStatus = .waiting
        signaling?.sendPairRequest(tag: code.tag, sealed: sealed)
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.failPairing("The other Mac did not answer.")
        }
    }

    public func cancelPairing() {
        pairingTimeout?.cancel()
        pairingTimeout = nil
        if shownCode != nil { signaling?.closePairing() }
        shownCode = nil
        typedCode = nil
        pairingStatus = .idle
    }

    /// Takes away that device's right to control this Mac.
    public func revokeControl(from device: PairedDevice) {
        if device.id == hostPeer?.id { endHosting(notify: true) }
        update(device.id) { $0.mayControlThisMac = false }
    }

    /// Forgets a Mac this one could control.
    public func forget(_ device: PairedDevice) {
        if device.id == controllerPeer?.id { disconnect() }
        update(device.id) { $0.thisMacMayControl = false }
    }

    private func update(_ id: String, _ change: (inout PairedDevice) -> Void) {
        guard let index = paired.firstIndex(where: { $0.id == id }) else { return }
        change(&paired[index])
        if !paired[index].mayControlThisMac, !paired[index].thisMacMayControl { paired.remove(at: index) }
        savePaired()
    }

    private func failPairing(_ reason: String) {
        guard typedCode != nil else { return }
        cancelPairing()
        pairingStatus = .failed(reason)
    }

    /// Host side: someone typed the code this Mac is showing.
    private func receivePairRequest(_ sealed: Data, from peerID: String) {
        guard let code = shownCode,
              let introduction = code.open(sealed, from: .controller),
              // The sender must be the device whose key is being introduced.
              DeviceID.derive(fromPublicKey: introduction.publicKey) == peerID, peerID != deviceID,
              let reply = code.seal(.init(publicKey: identity.publicKey, name: deviceName), from: .host)
        else { return }
        signaling?.sendPairReply(to: peerID, sealed: reply)
        cancelPairing() // the code is single-use
        store(PairedDevice(id: peerID, publicKey: introduction.publicKey, name: Self.label(introduction.name, id: peerID),
                           mayControlThisMac: true))
        notice = "\(Self.label(introduction.name, id: peerID)) can now control this Mac."
    }

    /// Controller side: the Mac showing the code answered.
    private func receivePairReply(_ sealed: Data, from peerID: String) {
        guard let code = typedCode,
              let introduction = code.open(sealed, from: .host),
              DeviceID.derive(fromPublicKey: introduction.publicKey) == peerID, peerID != deviceID
        else { return }
        cancelPairing()
        store(PairedDevice(id: peerID, publicKey: introduction.publicKey, name: Self.label(introduction.name, id: peerID),
                           thisMacMayControl: true))
    }

    /// Adds a pairing, or adds a direction to an existing one.
    private func store(_ device: PairedDevice) {
        if let index = paired.firstIndex(where: { $0.id == device.id }) {
            // Same ID means same key (the ID is derived from it); checked anyway.
            guard paired[index].publicKey == device.publicKey else { return }
            paired[index].name = device.name
            paired[index].mayControlThisMac = paired[index].mayControlThisMac || device.mayControlThisMac
            paired[index].thisMacMayControl = paired[index].thisMacMayControl || device.thisMacMayControl
        } else {
            paired.append(device)
        }
        savePaired()
    }

    private func savePaired() {
        defaults.set(try? JSONEncoder().encode(paired), forKey: Keys.paired)
    }

    // MARK: - Controlling another Mac

    public func connect(to host: PairedDevice) {
        guard signalingStatus == .online, let host = controllable.first(where: { $0.id == host.id }) else { return }
        disconnect()
        controllerPeer = host
        controllerStatus = .calling(host)
        Task {
            let servers = await iceServers()
            guard controllerPeer == host, controllerSession == nil else { return } // cancelled meanwhile
            startControlling(host, iceServers: servers)
        }
    }

    private func startControlling(_ host: PairedDevice, iceServers: [IceServer]) {
        guard let session = PeerSession(role: .controller, iceServers: iceServers, relayOnly: forcesRelay) else {
            return endControlling(.failed("Could not start a session"))
        }
        controllerSession = session

        session.onSignal = { [weak self] payload in
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                self.send(payload, to: host)
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
                case .connected:
                    self.controllerStatus = .connected(host)
                    guard self.controllerClipboard == nil else { break }
                    let clipboard = ClipboardSync()
                    clipboard.onLocalCopy = { [weak session] text in session?.send(.clipboard(text: text)) }
                    clipboard.start()
                    self.controllerClipboard = clipboard
                case .failed: self.endControlling(.failed("Connection to \(host.name) failed"))
                case .closed: self.endControlling(.idle)
                case .connecting, .disconnected: break
                }
            }
        }
        session.onClipboard = { [weak self] text in
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                self.controllerClipboard?.receive(text)
            }
        }
        send(.request, to: host)
    }

    /// Presses a shortcut on the host that this Mac's keyboard cannot send, because macOS acts on it here first.
    public func sendShortcut(_ shortcut: RemoteShortcut) {
        for message in shortcut.messages { controllerSession?.send(message) }
    }

    public func disconnect() {
        guard let controllerPeer else { return }
        send(.bye, to: controllerPeer)
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
        controllerClipboard?.stop()
        controllerClipboard = nil
        remoteVideo = nil
        remoteVideoSize = nil
        controllerStatus = status
        session?.close()
    }

    // MARK: - Being controlled

    private func beginHosting(for peer: PairedDevice) async {
        guard allowsControl else { return send(.bye, to: peer) }
        refreshPermissions()
        guard hasScreenPermission else {
            notice = "\(peer.name) tried to connect, but Screen Recording is not allowed for MacBridge."
            return send(.bye, to: peer)
        }
        // One controller at a time: a new request replaces the current session.
        // A retry from the same device must not get a bye: it would end the
        // attempt that the device has just started.
        endHosting(notify: hostPeer?.id != peer.id)
        hostPeer = peer
        let servers = await iceServers()
        guard hostPeer == peer, hostSession == nil,
              let session = PeerSession(role: .host, iceServers: servers, relayOnly: forcesRelay) else { return }
        hostSession = session

        session.onSignal = { [weak self] payload in
            Task { @MainActor in
                guard let self, self.hostSession === session else { return }
                self.send(payload, to: peer)
            }
        }
        session.onState = { [weak self] state in
            Task { @MainActor in
                guard let self, self.hostSession === session else { return }
                switch state {
                case .connected:
                    self.hostDisconnectTimer?.cancel()
                    self.hostDisconnectTimer = nil
                    guard self.hostStatus == .idle else { break }
                    self.hostStatus = .sharing(to: peer)
                    self.logSessionStart(peer)
                case .failed, .closed: self.endHosting(notify: false)
                case .disconnected:
                    guard self.hostDisconnectTimer == nil else { break }
                    self.hostDisconnectTimer = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        guard !Task.isCancelled, let self, self.hostSession === session else { return }
                        self.endHosting(notify: true)
                    }
                case .connecting: break
                }
            }
        }

        do {
            // A sleeping display gives the capturer nothing to send.
            power.keepDisplayAwake = true
            hostQuality = .sharp
            let display = try await startCapture(on: await displayForSession())
            guard hostSession === session else { return } // replaced while starting
            let injector = InputInjector(display: display)
            self.injector = injector
            let clipboard = ClipboardSync()
            clipboard.onLocalCopy = { [weak session] text in session?.send(.clipboard(text: text)) }
            clipboard.start()
            hostClipboard = clipboard
            session.onInput = { [weak self] message in
                switch message {
                case let .clipboard(text):
                    // Through the sync, so the copy is not sent straight back.
                    Task { @MainActor in
                        guard let self, self.hostSession === session else { return }
                        self.hostClipboard?.receive(text)
                    }
                case .nextDisplay, .quality:
                    Task { @MainActor in
                        guard let self, self.hostSession === session else { return }
                        await self.reconfigureCapture(message)
                    }
                default:
                    injector.handle(message)
                }
            }
            capturer.onFrame = { [weak session] buffer, timestampNs in
                session?.push(buffer, timestampNs: timestampNs)
            }
            session.start()
            PeerSession.writeStats("session started for \(peer.name)")
            Task { @MainActor [weak self, weak session] in
                while let self, let session, self.hostSession === session {
                    session.logStats()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            if !hasInputPermission {
                notice = "\(peer.name) can see this screen but not control it: Accessibility is not allowed for MacBridge."
            }
        } catch {
            notice = "Could not capture the screen: \(error.localizedDescription)"
            send(.bye, to: peer)
            endHosting(notify: false)
        }
    }

    /// The display a new session should show: nil (the main display) when
    /// this Mac has a working screen, otherwise a virtual display created for
    /// the session. A closed lid with no monitor would otherwise send black.
    private func displayForSession() async -> CGDirectDisplayID? {
        guard Headless.needsVirtualDisplay() else { return nil }
        if virtualDisplay == nil {
            do {
                virtualDisplay = try VirtualDisplay()
            } catch {
                notice = "This Mac has no screen turned on (lid closed?) and a virtual display could not be created; the picture may be black."
                return nil
            }
        }
        guard let virtual = virtualDisplay, await virtual.waitUntilOnline() else { return nil }
        // Capture may not list a brand-new display straight away.
        for _ in 0..<20 {
            if let displays = try? await ScreenCapturer.displays(), displays.contains(where: { $0.id == virtual.displayID }) {
                return virtual.displayID
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return virtual.displayID
    }

    private func startCapture(on displayID: CGDirectDisplayID?) async throws -> DisplayInfo {
        let display = try await capturer.start(
            displayID: displayID,
            maxPixelWidth: hostQuality.maxPixelWidth,
            maxPixelHeight: hostQuality.maxPixelHeight,
            framesPerSecond: hostQuality.framesPerSecond
        )
        hostDisplay = display
        return display
    }

    /// The controller asked for another display or another quality.
    private func reconfigureCapture(_ message: InputMessage) async {
        var target = hostDisplay?.id
        switch message {
        case let .quality(preset):
            guard preset != hostQuality else { return }
            hostQuality = preset
        case .nextDisplay:
            guard let displays = try? await ScreenCapturer.displays(), displays.count > 1 else { return }
            let index = displays.firstIndex { $0.id == hostDisplay?.id } ?? -1
            target = displays[(index + 1) % displays.count].id
        default:
            return
        }
        let session = hostSession
        guard let display = try? await startCapture(on: target), hostSession === session else { return }
        // Nothing may stay held on the display being left.
        injector?.releaseAll()
        injector?.setDisplay(display)
    }

    /// Ends the session in which this Mac is being controlled.
    public func endHostSession() {
        endHosting(notify: true)
    }

    private func endHosting(notify: Bool) {
        guard let peer = hostPeer else { return }
        if notify { send(.bye, to: peer) }
        hostDisconnectTimer?.cancel()
        hostDisconnectTimer = nil
        let session = hostSession
        hostSession = nil
        hostPeer = nil
        hostStatus = .idle
        power.keepDisplayAwake = false
        hostDisplay = nil
        logSessionEnd()
        capturer.onFrame = nil
        hostClipboard?.stop()
        hostClipboard = nil
        injector?.releaseAll()
        injector = nil
        session?.close()
        // The virtual display goes only after capture has stopped, so the
        // stream does not end with an error first.
        let virtual = virtualDisplay
        virtualDisplay = nil
        Task {
            await capturer.stop()
            withExtendedLifetime(virtual) {}
        }
    }

    // MARK: - Session log

    private func logSessionStart(_ peer: PairedDevice) {
        let entry = SessionLogEntry(deviceID: peer.id, deviceName: peer.name, started: Date())
        currentLogEntry = entry.id
        sessionLog.insert(entry, at: 0)
        sessionLog = Array(sessionLog.prefix(100))
        saveSessionLog()
    }

    private func logSessionEnd() {
        guard let id = currentLogEntry, let index = sessionLog.firstIndex(where: { $0.id == id }) else { return }
        currentLogEntry = nil
        sessionLog[index].ended = Date()
        saveSessionLog()
    }

    private func saveSessionLog() {
        defaults.set(try? JSONEncoder().encode(sessionLog), forKey: Keys.sessionLog)
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
        static let forcesRelay = "forcesRelay"
        static let paired = "pairedDevices"
        static let sessionLog = "sessionLog"
        static let publicKey = "publicKey"
    }

    /// The rule the server enforces for anything used as a device ID.
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

    /// The computer's name reduced to plain characters.
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

    /// A name supplied by another device, made safe to show: trimmed, capped,
    /// and never empty.
    nonisolated static func label(_ name: String, id: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .controlCharacters).joined()
        return trimmed.isEmpty ? "Mac \(id.prefix(4))" : String(trimmed.prefix(64))
    }
}

/// Where the access token is kept. The app uses the keychain; tests use memory.
public struct SecretStore: Sendable {
    public var accessToken: @Sendable () -> String
    public var setAccessToken: @Sendable (String) -> Void

    public static let keychain = SecretStore(
        accessToken: { Keychain.read("access-token").flatMap { String(data: $0, encoding: .utf8) } ?? "" },
        setAccessToken: { token in
            if token.isEmpty { Keychain.delete("access-token") } else { Keychain.write(Data(token.utf8), to: "access-token") }
        }
    )

    public static func inMemory(_ initial: String = "") -> SecretStore {
        let box = TokenBox(initial)
        return SecretStore(accessToken: { box.value }, setAccessToken: { box.value = $0 })
    }
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String
    init(_ value: String) { _value = value }
    var value: String {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
