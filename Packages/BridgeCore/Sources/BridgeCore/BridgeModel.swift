#if os(macOS)
import AppKit
#else
import UIKit
#endif
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

    public struct PendingRequest: Equatable, Sendable {
        public var peer: PairedDevice
        /// Without an answer by then, the request is declined.
        public var deadline: Date
    }


    public enum PairingStatus: Equatable {
        case idle
        /// This Mac is showing a code for another Mac to type.
        case showingCode(String, expires: Date)
        /// This Mac sent a typed code and is waiting for the other Mac.
        case waiting
        /// A pairing link names another server than the one set, or names the first server
        /// while an access token is waiting for one. Switching waits for a yes, so a link
        /// cannot move this device, or its token, to a server nobody chose. `sendsToken`:
        /// the token entered with no server set goes to this one.
        case confirmServer(String, sendsToken: Bool)
        case failed(String)
    }

    // Settings, saved as they change.
    @Published public var serverURL: String {
        didSet {
            defaults.set(serverURL, forKey: Keys.serverURL)
            serverChanged(from: oldValue)
        }
    }
    /// The token for the current server. Each server keeps its own, so a token
    /// is only ever sent to the server it was entered for.
    @Published public var accessToken: String { didSet { secrets.setToken(accessToken, Self.serverKey(serverURL)) } }
    /// Set while a confirmed pairing link switches the server.
    private var switchingByLink = false
    @Published public var deviceName: String { didSet { defaults.set(deviceName, forKey: Keys.deviceName) } }
    @Published public var forcesRelay: Bool { didSet { defaults.set(forcesRelay, forKey: Keys.forcesRelay) } }
    @Published public var allowsControl: Bool {
        didSet {
            defaults.set(allowsControl, forKey: Keys.allowsControl)
            if !allowsControl {
                declineRequest()
                endHosting(notify: true)
            }
            updatePower()
        }
    }

    /// What this Mac does with its lid closed while it allows control (laptops only).
    @Published public var lidClosedMode: LidClosedMode {
        didSet {
            defaults.set(lidClosedMode.rawValue, forKey: Keys.lidClosedMode)
            updatePower()
        }
    }
    /// Staying awake with the lid closed needs LidAwake on this Mac.
    public var canStayAwakeLidClosed: Bool { lidKeeper.isAvailable }
    public let hasLid = LidAndPower.hasLid

    @Published public private(set) var paired: [PairedDevice] = []
    /// Alias, favourite and last use per paired device, by device ID.
    @Published public private(set) var meta: [String: DeviceMeta] = [:]
    /// Which paired devices are connected to the server right now. A device missing here is unknown.
    @Published public private(set) var presence: [String: Bool] = [:]
    @Published public private(set) var signalingStatus: SignalingClient.Status = .offline {
        didSet {
            updatePower()
            if signalingStatus == .online, let code = codeAwaitingServer {
                codeAwaitingServer = nil
                pair(usingCode: code)
            }
        }
    }
    /// A scanned pairing code kept until the server it came with answers.
    private var codeAwaitingServer: String?
    /// A pairing link for another server, kept until the switch is confirmed or cancelled.
    private var linkAwaitingConfirm: PairingLink?
    /// Who controlled this Mac and when, newest first.
    @Published public private(set) var sessionLog: [SessionLogEntry] = []
    @Published public private(set) var controllerStatus: ControllerStatus = .idle
    @Published public private(set) var hostStatus: HostStatus = .idle
    @Published public private(set) var pairingStatus: PairingStatus = .idle
    @Published public private(set) var remoteVideo: RemoteVideo?
    @Published public private(set) var remoteVideoSize: CGSize?
    /// The host's displays, for the session window's display menu. Empty with an older host.
    @Published public private(set) var remoteDisplays: [RemoteDisplay] = []
    /// Connection figures for the session window, refreshed every second while connected.
    @Published public private(set) var sessionStats: SessionStats?
    /// A Mac set to "ask first" wants to connect and waits for Accept or Decline here.
    @Published public private(set) var pendingRequest: PendingRequest?
    /// When the session in which this Mac is being controlled started.
    @Published public private(set) var hostSince: Date?
    /// The Mac the last session was with, so a dropped session can be started again.
    @Published public private(set) var lastHost: PairedDevice?
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
    /// Internal for tests.
    let power = PowerAssertions()
    private let lidKeeper: LidClosedKeeper
    private var lidTimer: Task<Void, Never>?
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

    public init(identity: Identity, defaults: UserDefaults = .standard, secrets: SecretStore = .keychain,
                lidKeeper: LidClosedKeeper? = nil) {
        self.identity = identity
        self.lidKeeper = lidKeeper ?? LidClosedKeeper()
        lidClosedMode = defaults.string(forKey: Keys.lidClosedMode).flatMap(LidClosedMode.init) ?? .off
        self.defaults = defaults
        self.secrets = secrets
        let server = defaults.string(forKey: Keys.serverURL) ?? ""
        serverURL = server
        // Before tokens were kept per server there was one; it belongs to the server saved then.
        let key = Self.serverKey(server)
        if !key.isEmpty, secrets.token(key).isEmpty, !secrets.token("").isEmpty {
            secrets.setToken(secrets.token(""), key)
            secrets.setToken("", "")
        }
        accessToken = secrets.token(key)
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Self.defaultDeviceName()
        forcesRelay = defaults.bool(forKey: Keys.forcesRelay)
        allowsControl = defaults.bool(forKey: Keys.allowsControl)
        paired = defaults.data(forKey: Keys.paired)
            .flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
        meta = defaults.data(forKey: Keys.meta)
            .flatMap { try? JSONDecoder().decode([String: DeviceMeta].self, from: $0) } ?? [:]
        sessionLog = defaults.data(forKey: Keys.sessionLog)
            .flatMap { try? JSONDecoder().decode([SessionLogEntry].self, from: $0) } ?? []
        // Public, and handy for provisioning: scripts/link-remote.sh pairs two
        // Macs you already control by exchanging these over SSH.
        defaults.set(identity.publicKey.base64EncodedString(), forKey: Keys.publicKey)
        capturer.onStop = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Display unplugged, lid closed: capture what is left (or a virtual display).
                // The session ends only if nothing can be captured. Before the first
                // capture is shown there is nothing to fall back to.
                if self.hostSession != nil, self.hostDisplay != nil {
                    self.reconfigureCapture(.captureStopped)
                } else {
                    self.endHosting(notify: true)
                }
            }
        }
        #if os(macOS)
        // After sleep the socket is often dead without having said so: check it at once.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.signaling?.reconnectIfStale() }
        }
        #endif
    }

    #if os(macOS)
    private var wakeObserver: NSObjectProtocol?
    #endif

    /// The app came to the front: be online again as soon as possible. A connection that is
    /// still trying reconnects now instead of waiting out its backoff.
    public func resumeConnection() {
        if let signaling {
            signaling.reconnectIfStale()
        } else if signalingStatus == .offline, canGoOnline {
            goOnline()
        }
    }

    /// While this Mac accepts control and is meant to be online, it must not
    /// fall asleep, or it would drop off the server.
    private func updatePower() {
        power.keepSystemAwake = allowsControl && signaling != nil
        updateLidHold()
        // The power adapter may be unplugged, and a hold has to be renewed: look again every minute
        // for as long as a hold could be wanted.
        let watch = hasLid && lidClosedMode != .off && allowsControl && signaling != nil
        if watch, lidTimer == nil {
            lidTimer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    self?.updateLidHold()
                }
            }
        } else if !watch {
            lidTimer?.cancel()
            lidTimer = nil
        }
    }

    private func updateLidHold() {
        guard hasLid else { return }
        lidKeeper.update(shouldHold: lidClosedMode.shouldHold(
            allowsControl: allowsControl, isOnline: signaling != nil,
            isOnPower: LidAndPower.isOnPowerAdapter, inSession: hostSession != nil))
    }

    /// Lets the Mac sleep again when MacBridge quits.
    public func releaseLidHold() {
        lidKeeper.update(shouldHold: false)
    }

    public var parsedServerURL: URL? { Self.parseServerURL(serverURL) }
    public var canGoOnline: Bool { parsedServerURL != nil }
    /// Devices this Mac can control.
    public var controllable: [PairedDevice] { paired.filter(\.thisMacMayControl) }
    /// Devices that can control this Mac.
    public var controllers: [PairedDevice] { paired.filter(\.mayControlThisMac) }

    /// Asks the server which paired Macs are connected. Called while the list of Macs is on screen.
    public func refreshPresence() {
        let ids = paired.map(\.id)
        guard let signaling, signalingStatus == .online, !ids.isEmpty else {
            if !presence.isEmpty { presence = [:] }
            return
        }
        signaling.presence(of: ids) { [weak self] online in
            Task { @MainActor in
                guard let self else { return }
                let fresh = online.map { online in Dictionary(uniqueKeysWithValues: ids.map { ($0, online.contains($0)) }) } ?? [:]
                if fresh != self.presence { self.presence = fresh }
            }
        }
    }

    // MARK: - Names, favourites, last use

    /// The name a device is shown under on this Mac.
    public func displayName(_ device: PairedDevice) -> String {
        meta[device.id]?.alias ?? device.name
    }

    public var displayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: paired.map { ($0.id, displayName($0)) })
    }

    /// Devices this Mac can control: favourites first, then most recently used, then by name.
    public var controllableSorted: [PairedDevice] {
        controllable.sorted { a, b in
            let ma = meta[a.id] ?? DeviceMeta(), mb = meta[b.id] ?? DeviceMeta()
            if ma.isFavourite != mb.isFavourite { return ma.isFavourite }
            if ma.lastConnected != mb.lastConnected { return (ma.lastConnected ?? .distantPast) > (mb.lastConnected ?? .distantPast) }
            return displayName(a).localizedCaseInsensitiveCompare(displayName(b)) == .orderedAscending
        }
    }

    /// An empty name removes the alias.
    public func rename(_ device: PairedDevice, to alias: String) {
        let trimmed = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        updateMeta(device.id) { $0.alias = trimmed.isEmpty || trimmed == device.name ? nil : trimmed }
    }

    public func setFavourite(_ device: PairedDevice, _ favourite: Bool) {
        updateMeta(device.id) { $0.isFavourite = favourite }
    }

    public func setAsksFirst(_ device: PairedDevice, _ asks: Bool) {
        updateMeta(device.id) { $0.asksFirst = asks }
    }

    private func updateMeta(_ id: String, _ change: (inout DeviceMeta) -> Void) {
        var entry = meta[id] ?? DeviceMeta()
        change(&entry)
        meta[id] = entry == DeviceMeta() ? nil : entry
        defaults.set(try? JSONEncoder().encode(meta), forKey: Keys.meta)
    }

    // MARK: - Signaling

    /// Connects to the signaling server with the current settings, replacing
    /// any existing connection.
    public func goOnline() {
        goOffline()
        guard let url = parsedServerURL else { return }
        let client = SignalingClient(url: url, identity: identity, accessToken: accessToken)
        // Callbacks queued by a client that has since been replaced (going offline, another
        // server) are dropped: a late "offline" must not overwrite the new client's status.
        client.onStatus = { [weak self, weak client] status in
            guard let self, self.signaling === client else { return }
            self.signalingStatus = status
        }
        client.onSignal = { [weak self, weak client] from, envelope in
            guard let self, self.signaling === client else { return }
            self.receive(envelope, from: from)
        }
        client.onError = { [weak self, weak client] error in
            guard let self, self.signaling === client else { return }
            self.receive(error)
        }
        client.onPairRequest = { [weak self, weak client] from, sealed in
            guard let self, self.signaling === client else { return }
            self.receivePairRequest(sealed, from: from)
        }
        client.onPairReply = { [weak self, weak client] from, sealed in
            guard let self, self.signaling === client else { return }
            self.receivePairReply(sealed, from: from)
        }
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

    private func send(_ payload: SignalPayload, to peer: PairedDevice, reason: ByeReason? = nil) {
        PeerSession.writeStats("signal out to \(peer.name): \(PeerSession.kind(payload)) (server \(signaling == nil ? "none" : "ok"))")
        let auth = SessionAuth.sign(payload, to: peer.id, identity: identity)
        signaling?.send(SignalEnvelope(payload, auth: auth, reason: reason), to: peer.id)
    }

    /// Turns a request away with a reason the caller can show.
    private func refuse(_ peer: PairedDevice, _ reason: ByeReason) {
        send(.bye, to: peer, reason: reason)
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
            // Correctly signed but too old or too new: most likely one of the clocks is off. Say so,
            // or the caller only sees no answer.
            if payload == .request, error as? SessionAuth.Failure == .stale {
                refuse(peer, peer.mayControlThisMac ? .stale : .notAllowed)
            }
            return
        }
        if peer.id != hostPeer?.id, payload != .request {
            PeerSession.writeStats("signal from \(peer.name) ignored, no host session for it: \(PeerSession.kind(payload))")
        }

        if peer.id == controllerPeer?.id, peer.thisMacMayControl, payload != .request {
            if payload == .bye {
                // A reason only explains a call still waiting for this host; it is unsigned.
                if let reason = envelope.reason, case let .calling(host) = controllerStatus, host.id == peer.id {
                    return endControlling(.failed(Self.refusal(reason, from: displayName(peer))))
                }
                // Before any picture arrived, a bye means the other Mac said no.
                let refused = remoteVideo == nil
                endControlling(.failed(refused ? "\(displayName(peer)) did not accept the connection" : "\(displayName(peer)) ended the session"))
            } else {
                controllerSession?.handle(payload)
            }
            return
        }
        switch payload {
        case .request:
            guard peer.mayControlThisMac else { return refuse(peer, .notAllowed) }
            lastRequest[peerID] = requestTimestamp
            // A Mac set to "ask first" waits for someone here to accept, unless it is already
            // in a session with this Mac (the request is then a retry).
            if meta[peer.id]?.asksFirst == true, hostPeer?.id != peer.id, allowsControl {
                ask(about: peer)
            } else {
                Task { await beginHosting(for: peer) }
            }
        case .bye:
            if peer.id == pendingRequest?.peer.id { clearPendingRequest() }
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
            // The client has stopped for good: let go of it, and of the wake lock held for it.
            signaling = nil
            signalingStatus = .offline
            notice = code == "bad-token"
                ? "The server refused the access token."
                : "The server refused this device (\(code))."
        case .replaced:
            signaling = nil
            signalingStatus = .offline
            #if os(macOS)
            notice = "This Mac is online from another copy of MacBridge. Go online again here to take over."
            #else
            notice = "This device is online from another copy of MacBridge. Go online again here to take over."
            #endif
        case .unsupported:
            break // never passed on by the client
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

    /// Pairs from a scanned or opened pairing link. With no server and no token set yet it
    /// takes the link's server; otherwise another server waits for `confirmServerSwitch()`.
    /// Offline, it goes online and pairs once the server answers.
    public func pair(using link: PairingLink) {
        cancelPairing()
        if let server = link.server, Self.serverKey(server) != Self.serverKey(serverURL) {
            // A link can come from anyone: ask before leaving the server the user chose, or
            // before sending it the token the user entered.
            if canGoOnline || !accessToken.isEmpty {
                guard !inSession else {
                    pairingStatus = .failed("End the current session before pairing with another server.")
                    return
                }
                cancelPairing()
                linkAwaitingConfirm = link
                pairingStatus = .confirmServer(server, sendsToken: !canGoOnline)
                return
            }
            // First-time setup with nothing to lose: the link's server becomes this device's server.
            serverURL = server
            goOnline()
        } else if signalingStatus == .offline, canGoOnline {
            goOnline()
        }
        continuePairing(link)
    }

    /// Switches to the server of the link waiting in `.confirmServer` and pairs. Leaving a set
    /// server, it uses the new server's own token (none if it is new); with no server set, the
    /// token entered goes with it.
    public func confirmServerSwitch() {
        guard let link = linkAwaitingConfirm, let server = link.server else { return }
        linkAwaitingConfirm = nil
        guard !inSession else {
            pairingStatus = .failed("End the current session before pairing with another server.")
            return
        }
        switchingByLink = canGoOnline
        serverURL = server
        switchingByLink = false
        goOnline()
        continuePairing(link)
    }

    private var inSession: Bool { controllerPeer != nil || hostPeer != nil }

    private func continuePairing(_ link: PairingLink) {
        guard canGoOnline else {
            pairingStatus = .failed("Set the server in Settings first, then scan again.")
            return
        }
        if signalingStatus == .online { return pair(usingCode: link.code) }
        codeAwaitingServer = link.code
        pairingStatus = .waiting
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.codeAwaitingServer != nil else { return }
            self.cancelPairing()
            self.pairingStatus = .failed("Can't reach the server. If it is on a Tailscale network, turn Tailscale on.")
        }
    }

    /// Sends a code typed on this Mac to the Mac that is showing it.
    public func pair(usingCode text: String) {
        cancelPairing()
        guard signalingStatus == .online else { return }
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
        codeAwaitingServer = nil
        linkAwaitingConfirm = nil
        pairingStatus = .idle
    }

    /// Keeps each server's token with that server. A confirmed link loads the new server's
    /// own token, empty if it has none. A server committed in Settings loads its own token if
    /// it has one, otherwise the token shown is copied to it: the old server keeps its token.
    /// Only a token not yet tied to a server moves.
    private func serverChanged(from old: String) {
        let oldKey = Self.serverKey(old), newKey = Self.serverKey(serverURL)
        guard oldKey != newKey else { return }
        let stored = secrets.token(newKey)
        if switchingByLink || !stored.isEmpty {
            accessToken = stored
        } else {
            let carried = accessToken
            accessToken = carried
            if oldKey.isEmpty { secrets.setToken("", oldKey) }
        }
    }

    /// Applies the Settings connection fields once they are committed (submit, leaving the
    /// field, Go online), not on every keystroke. `token` nil: the token field was not edited,
    /// so the server's own token is loaded.
    public func applyConnectionSettings(server: String, token: String?) {
        if server != serverURL { serverURL = server }
        if let token, token != accessToken { accessToken = token }
    }

    /// Takes away that device's right to control this Mac.
    public func revokeControl(from device: PairedDevice) {
        if device.id == hostPeer?.id { endHosting(notify: true) }
        // A question still showing must not let it in after all.
        if device.id == pendingRequest?.peer.id { declineRequest() }
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
        lastHost = host
        controllerStatus = .calling(host)
        let timeout = callTimeout
        callTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, case let .calling(calling) = self.controllerStatus, calling.id == host.id else { return }
            self.send(.bye, to: host)
            self.endControlling(.failed("No answer from \(self.displayName(host)). Check that it is awake, online and allows control."))
        }
        Task {
            let servers = await iceServers()
            guard controllerPeer == host, controllerSession == nil else { return } // cancelled meanwhile
            startControlling(host, iceServers: servers)
        }
    }

    /// A call the host has not answered by then fails. Internal so tests can shorten it.
    var callTimeout: TimeInterval = 25
    private var callTimer: Task<Void, Never>?

    /// What the controller shows when the host turns a request away.
    nonisolated static func refusal(_ reason: ByeReason, from name: String) -> String {
        switch reason {
        case .notAllowed:
            return "\(name) does not allow control from this device right now."
        case .stale:
            return "\(name) turned the request away because the clocks differ. Both clocks must be within a minute of each other: set the date and time automatically on both."
        case .noScreenPermission:
            return "\(name) can't share its screen: Screen Recording is not allowed for MacBridge there."
        }
    }

    private func startControlling(_ host: PairedDevice, iceServers: [IceServer]) {
        guard let session = PeerSession(role: .controller, iceServers: iceServers, relayOnly: forcesRelay) else {
            return endControlling(.failed("Could not start a session"))
        }
        controllerSession = session

        // The callbacks are stored on the session: they hold it weakly, or it could never be freed.
        session.onSignal = { [weak self, weak session] payload in
            guard let session else { return }
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                self.send(payload, to: host)
            }
        }
        session.onRemoteVideoTrack = { [weak self, weak session] track in
            guard let session else { return }
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                self.remoteVideo = RemoteVideo(track: track)
            }
        }
        session.onState = { [weak self, weak session] state in
            guard let session else { return }
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                switch state {
                case .connected:
                    self.controllerStatus = .connected(host)
                    self.updateMeta(host.id) { $0.lastConnected = Date() }
                    self.startStatsPolling(session)
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
        session.onClipboard = { [weak self, weak session] text in
            guard let session else { return }
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                self.controllerClipboard?.receive(text)
            }
        }
        session.onDisplays = { [weak self, weak session] displays in
            guard let session else { return }
            Task { @MainActor in
                guard let self, self.controllerSession === session else { return }
                self.remoteDisplays = displays
            }
        }
        send(.request, to: host)
    }

    /// Connects again to the Mac of the session that just ended or failed.
    public func reconnect() {
        guard let lastHost else { return }
        connect(to: lastHost)
    }

    /// Leaves a failed session's screen and goes back to the list of Macs.
    public func dismissFailure() {
        if case .failed = controllerStatus { controllerStatus = .idle }
    }

    public func selectDisplay(_ display: RemoteDisplay) {
        controllerSession?.send(.selectDisplay(id: display.id))
    }

    private func startStatsPolling(_ session: PeerSession) {
        Task { @MainActor [weak self, weak session] in
            var previous: (bytes: Int64, at: Date)?
            while let self, let session, self.controllerSession === session {
                let stats: SessionStats = await withCheckedContinuation { done in session.sessionStats { done.resume(returning: $0) } }
                guard self.controllerSession === session else { return }
                var shown = stats
                let now = Date()
                if let previous, now > previous.at, stats.videoBytes >= previous.bytes {
                    shown.bitsPerSecond = Double(stats.videoBytes - previous.bytes) * 8 / now.timeIntervalSince(previous.at)
                }
                previous = (stats.videoBytes, now)
                self.sessionStats = shown
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    #if os(iOS)
    /// The newest text copied on the Mac during this session, for "Get Mac's clipboard".
    public var hostClipboardText: String? { controllerClipboard?.latestRemote }
    #endif

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
        callTimer?.cancel()
        callTimer = nil
        let session = controllerSession
        controllerSession = nil
        controllerPeer = nil
        controllerClipboard?.stop()
        controllerClipboard = nil
        remoteVideo = nil
        remoteVideoSize = nil
        remoteDisplays = []
        sessionStats = nil
        controllerStatus = status
        session?.close()
    }

    // MARK: - Being controlled

    private var askTimer: Task<Void, Never>?
    /// How long an "ask first" request waits for an answer before it is declined.
    public var askTimeout: TimeInterval = 30

    private func ask(about peer: PairedDevice) {
        let timeout = askTimeout
        // The same Mac asking again (it retries while waiting) keeps the question that is showing.
        if pendingRequest?.peer.id == peer.id { return }
        if let other = pendingRequest?.peer { send(.bye, to: other) }
        askTimer?.cancel()
        pendingRequest = PendingRequest(peer: peer, deadline: Date().addingTimeInterval(timeout))
        askTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pendingRequest?.peer.id == peer.id else { return }
            self.declineRequest()
        }
    }

    private func clearPendingRequest() {
        askTimer?.cancel()
        askTimer = nil
        pendingRequest = nil
    }

    /// Lets the waiting Mac in.
    public func acceptRequest() {
        guard let peer = pendingRequest?.peer else { return }
        clearPendingRequest()
        Task { await beginHosting(for: peer) }
    }

    /// Turns the waiting Mac away.
    public func declineRequest() {
        guard let peer = pendingRequest?.peer else { return }
        clearPendingRequest()
        send(.bye, to: peer)
    }

    private func beginHosting(for peer: PairedDevice) async {
        // Looked up again: the right may have been taken away since the request came in.
        guard allowsControl, paired.first(where: { $0.id == peer.id })?.mayControlThisMac == true else {
            return refuse(peer, .notAllowed)
        }
        refreshPermissions()
        guard hasScreenPermission else {
            notice = "\(peer.name) tried to connect, but Screen Recording is not allowed for MacBridge."
            return refuse(peer, .noScreenPermission)
        }
        // One controller at a time: a new request replaces the current session.
        // A retry from the same device must not get a bye: it would end the
        // attempt that the device has just started. A virtual display stays for
        // the new session: capturing it while it is being removed would fail.
        endHosting(notify: hostPeer?.id != peer.id, keepVirtualDisplay: true)
        hostPeer = peer
        let servers = await iceServers()
        guard hostPeer == peer, hostSession == nil else { return }
        guard let session = PeerSession(role: .host, iceServers: servers, relayOnly: forcesRelay) else {
            notice = "Could not start a session for \(peer.name)."
            return endHosting(notify: true)
        }
        hostSession = session
        updateLidHold()

        // The callbacks are stored on the session: they hold it weakly, or it could never be freed.
        session.onSignal = { [weak self, weak session] payload in
            guard let session else { return }
            Task { @MainActor in
                guard let self, self.hostSession === session else { return }
                self.send(payload, to: peer)
            }
        }
        session.onState = { [weak self, weak session] state in
            guard let session else { return }
            Task { @MainActor in
                guard let self, self.hostSession === session else { return }
                switch state {
                case .connected:
                    self.hostDisconnectTimer?.cancel()
                    self.hostDisconnectTimer = nil
                    guard self.hostStatus == .idle else { break }
                    self.hostStatus = .sharing(to: peer)
                    self.hostSince = Date()
                    self.logSessionStart(peer)
                case .failed, .closed: self.endHosting(notify: false)
                case .disconnected:
                    // The key-ups may never come: let go now rather than in 10 seconds.
                    self.injector?.releaseAll()
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
            let display = try await startCapture(on: await displayForSession(), quality: hostQuality, for: session)
            guard hostSession === session else {
                // Ended while starting: make sure nothing keeps capturing. A session that
                // replaced this one starts its own capture after this stop.
                if hostSession == nil { stopCapture() }
                return
            }
            hostDisplay = display
            shownQuality = hostQuality
            // The clipboard is written from the injector's queue, so text sent ahead of ⌘V is
            // on the clipboard before the ⌘V is injected. Through the sync, so the copy is not
            // sent straight back.
            let injector = InputInjector(display: display, writeClipboard: { [weak self] text in
                MainActor.assumeIsolated { self?.hostClipboard?.receive(text) }
            })
            self.injector = injector
            let clipboard = ClipboardSync()
            clipboard.onLocalCopy = { [weak session] text in session?.send(.clipboard(text: text)) }
            clipboard.start()
            hostClipboard = clipboard
            session.onInput = { [weak self, weak session] message in
                switch message {
                case .nextDisplay, .quality, .selectDisplay:
                    guard let session else { return }
                    Task { @MainActor in
                        guard let self, self.hostSession === session else { return }
                        self.reconfigureCapture(.request(message))
                    }
                default:
                    injector.handle(message)
                }
            }
            session.onInputReady = { [weak self, weak session] in
                guard let session else { return }
                Task { @MainActor in
                    guard let self, self.hostSession === session else { return }
                    await self.sendDisplays()
                }
            }
            capturer.setOnFrame { [weak session] buffer, timestampNs in
                session?.push(buffer, timestampNs: timestampNs)
            }
            // Displays plugged in, unplugged or set to another resolution mid-session.
            displayWatcher = DisplayChangeWatcher { [weak self] changed in
                MainActor.assumeIsolated { self?.displaysChanged(changed) }
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
            // Ended or replaced while starting: not a capture failure.
            guard hostSession === session else { return }
            notice = "Could not capture the screen: \(error.localizedDescription)"
            send(.bye, to: peer)
            endHosting(notify: false)
        }
    }

    /// The display a new session should show: nil (the main display) when
    /// this Mac has a working screen, otherwise a virtual display created for
    /// the session. A closed lid with no monitor would otherwise send black.
    private func displayForSession() async -> CGDirectDisplayID? {
        // A virtual display kept from the session this one replaced is no screen anyone sees.
        guard Headless.needsVirtualDisplay(ignoring: virtualDisplay?.displayID) else {
            if let kept = virtualDisplay {
                virtualDisplay = nil
                release(kept)
            }
            return nil
        }
        if virtualDisplay == nil {
            do {
                let created = try VirtualDisplay()
                releasedDisplays.remove(created.displayID) // the ID may be handed out again
                virtualDisplay = created
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

    // MARK: Capture start and stop

    /// Every capture start and stop, in the order asked for. Each waits for the
    /// one before, so a stop can never be overtaken by an older start, and two
    /// starts never run at once.
    private var captureChain: Task<Void, Never>?

    private func enqueueCapture<T>(_ work: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        let previous = captureChain
        let task = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        captureChain = Task { _ = await task.result }
        return task
    }

    /// Starts capture for `session`, unless that session has ended by its turn.
    private func startCapture(on displayID: CGDirectDisplayID?, quality: QualityPreset,
                              for session: PeerSession) async throws -> DisplayInfo {
        try await enqueueCapture { [weak self, capturer] in
            guard let self, self.hostSession === session else { throw CancellationError() }
            return try await capturer.start(
                displayID: displayID,
                maxPixelWidth: quality.maxPixelWidth,
                maxPixelHeight: quality.maxPixelHeight,
                framesPerSecond: quality.framesPerSecond
            )
        }.value
    }

    /// Virtual displays let go of whose removal is still to be reported. Their
    /// removal is expected, not a change for the session to react to.
    private var releasedDisplays: Set<CGDirectDisplayID> = []

    /// Stops capture, then removes the virtual display.
    private func release(_ virtual: VirtualDisplay) {
        releasedDisplays.insert(virtual.displayID)
        stopCapture(releasing: virtual)
    }

    /// The virtual display goes only after capture has stopped, so the
    /// stream does not end with an error first.
    private func stopCapture(releasing virtual: VirtualDisplay? = nil) {
        _ = enqueueCapture { [capturer] in
            await capturer.stop()
            withExtendedLifetime(virtual) {}
        }
    }

    // MARK: Changing what is captured

    private enum CaptureChange: Equatable {
        /// From the controller: `.quality`, `.nextDisplay` or `.selectDisplay`.
        case request(InputMessage)
        case displaysChanged
        /// The system stopped the capture stream (its display went away).
        case captureStopped
    }

    /// What a display change, or a stopped stream, means for the display being shown.
    enum DisplayCheck: Equatable {
        case unchanged
        /// Still there: start again on it (moved, resized, or the stream stopped).
        case restart
        /// No longer listed: pick another.
        case gone
    }

    /// `listed`: the displays capture offers now; nil if they could not be read.
    nonisolated static func check(shown id: CGDirectDisplayID?, as shownInfo: DisplayInfo?, listed: [DisplayInfo]?,
                                  captureStopped: Bool) -> DisplayCheck {
        guard let listed else { return captureStopped ? .restart : .unchanged }
        guard let now = listed.first(where: { $0.id == id }) else { return .gone }
        return captureStopped || now != shownInfo ? .restart : .unchanged
    }

    /// From the watcher: the displays that changed, true for a removed one.
    private func displaysChanged(_ changed: [CGDirectDisplayID: Bool]) {
        let expected = Set(changed.filter { $0.value && releasedDisplays.contains($0.key) }.keys)
        releasedDisplays.subtract(expected)
        guard changed.count > expected.count else { return }
        reconfigureCapture(.displaysChanged)
    }

    /// Capture changes run one at a time, in order.
    private var reconfigureTask: Task<Void, Never>?
    private var reconfigureCount = 0
    /// What the changes so far ask for. Only the newest change restarts
    /// capture, with all of them applied.
    private var wantedDisplay: CGDirectDisplayID?
    private var wantsRestart = false
    /// The quality of the capture that is running, to fall back to.
    private var shownQuality = QualityPreset.sharp
    private var displayWatcher: DisplayChangeWatcher?

    /// The controller asked for another display or another quality, or this Mac's displays changed.
    private func reconfigureCapture(_ change: CaptureChange) {
        guard let session = hostSession else { return }
        reconfigureCount += 1
        let number = reconfigureCount, previous = reconfigureTask
        reconfigureTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.hostSession === session else { return }
            await self.apply(change, number: number, session: session)
        }
    }

    private func apply(_ change: CaptureChange, number: Int, session: PeerSession) async {
        var target = wantsRestart ? wantedDisplay : hostDisplay?.id
        var changed = false
        switch change {
        case let .request(.quality(preset)):
            changed = preset != hostQuality
            hostQuality = preset
        case .request(.nextDisplay):
            if let displays = try? await ScreenCapturer.displays(), displays.count > 1 {
                let index = displays.firstIndex { $0.id == target } ?? -1
                target = displays[(index + 1) % displays.count].id
                changed = true
            }
        case let .request(.selectDisplay(id)):
            if id != target, let displays = try? await ScreenCapturer.displays(), displays.contains(where: { $0.id == id }) {
                target = id
                changed = true
            }
        case .displaysChanged, .captureStopped:
            let listed = try? await ScreenCapturer.displays()
            switch Self.check(shown: target, as: hostDisplay, listed: listed, captureStopped: change == .captureStopped) {
            case .unchanged:
                break
            case .restart:
                // Moved or resized: the pointer mapping and the stream size follow.
                changed = true
            case .gone:
                // As for a new session: the main display, or a virtual one when no screen is left
                // (lid closed, no monitor).
                guard hostSession === session else { return }
                target = await displayForSession()
                changed = true
            }
        case .request:
            break
        }
        guard hostSession === session else { return }
        wantedDisplay = target
        wantsRestart = wantsRestart || changed
        // A newer change is waiting: it restarts capture once, with this one included.
        guard number == reconfigureCount, wantsRestart else { return }
        wantsRestart = false

        let fallback = (display: hostDisplay?.id, quality: shownQuality)
        if let display = try? await startCapture(on: target, quality: hostQuality, for: session) {
            return await show(display, quality: hostQuality, session: session)
        }
        guard hostSession === session else { return }
        // Back to what was shown before; with nothing to show, the session ends.
        hostQuality = fallback.quality
        if let display = try? await startCapture(on: fallback.display, quality: fallback.quality, for: session) {
            return await show(display, quality: fallback.quality, session: session)
        }
        guard hostSession === session else { return }
        notice = "The screen could not be captured any more."
        endHosting(notify: true)
    }

    private func show(_ display: DisplayInfo, quality: QualityPreset, session: PeerSession) async {
        guard hostSession === session else { return }
        hostDisplay = display
        shownQuality = quality
        // Nothing may stay held on the display being left.
        injector?.releaseAll()
        injector?.setDisplay(display)
        await sendDisplays()
    }

    /// Tells the controller which displays this Mac has and which one it is looking at.
    private func sendDisplays() async {
        guard let session = hostSession, let displays = try? await ScreenCapturer.displays(), hostSession === session else { return }
        var names: [CGDirectDisplayID: String] = [:]
        #if os(macOS)
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID { names[id] = screen.localizedName }
        }
        #endif
        let list = displays.enumerated().map { index, display in
            RemoteDisplay(id: display.id, name: names[display.id] ?? "Display \(index + 1)",
                          pixelWidth: UInt32(display.pixelSize.width), pixelHeight: UInt32(display.pixelSize.height),
                          isMain: display.isMain, isCurrent: display.id == hostDisplay?.id)
        }
        session.send(.displays(list))
    }

    /// Ends the session in which this Mac is being controlled.
    public func endHostSession() {
        endHosting(notify: true)
    }

    /// The app is quitting: end the session, waiting until every key and
    /// button the controller held is released, and let the Mac sleep again.
    public func prepareForQuit() {
        endHosting(notify: true, waitForInputRelease: true)
        releaseLidHold()
    }

    /// - Parameters:
    ///   - keepVirtualDisplay: a new session takes over the virtual display.
    ///   - waitForInputRelease: return only once held keys and buttons are let go.
    private func endHosting(notify: Bool, keepVirtualDisplay: Bool = false, waitForInputRelease: Bool = false) {
        guard let peer = hostPeer else { return }
        if notify { send(.bye, to: peer) }
        hostDisconnectTimer?.cancel()
        hostDisconnectTimer = nil
        let session = hostSession
        hostSession = nil
        hostPeer = nil
        hostStatus = .idle
        hostSince = nil
        updateLidHold()
        power.keepDisplayAwake = false
        hostDisplay = nil
        logSessionEnd()
        capturer.setOnFrame(nil)
        displayWatcher = nil
        reconfigureTask?.cancel()
        reconfigureTask = nil
        wantsRestart = false
        hostClipboard?.stop()
        hostClipboard = nil
        // First no more input, then let go of everything: input still arriving
        // could otherwise press a key again after its release.
        session?.onInput = nil
        injector?.stop(waitUntilDone: waitForInputRelease)
        injector = nil
        session?.close()
        if !keepVirtualDisplay, let virtual = virtualDisplay {
            virtualDisplay = nil
            release(virtual)
        } else {
            stopCapture()
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
        static let meta = "deviceMeta"
        static let lidClosedMode = "lidClosedMode"
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

    /// The form of a server address that tokens are kept under: scheme, host, port and
    /// path, without case or a trailing slash. Empty for no valid server.
    nonisolated public static func serverKey(_ text: String) -> String {
        guard let url = parseServerURL(text), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
        else { return "" }
        let port = url.port.map { ":\($0)" } ?? ""
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }

    /// The computer's name reduced to plain characters.
    nonisolated public static func defaultDeviceName(from hostName: String? = BridgeModel.systemDeviceName) -> String {
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
    /// What the system calls this device.
    nonisolated public static var systemDeviceName: String? {
        #if os(macOS)
        return Host.current().localizedName
        #else
        // Not ProcessInfo.hostName: on iOS it waits on a network name lookup, and at launch
        // that blocks the main thread until iOS kills the app.
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { UIDevice.current.name }
        #endif
    }

    nonisolated static func label(_ name: String, id: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .controlCharacters).joined()
        return trimmed.isEmpty ? "Mac \(id.prefix(4))" : String(trimmed.prefix(64))
    }
}

/// Where access tokens are kept, one per server key (`BridgeModel.serverKey`). The key ""
/// holds a token not yet tied to a server, and the single token of older versions.
/// The app uses the keychain; tests use memory.
public struct SecretStore: Sendable {
    public var token: @Sendable (_ server: String) -> String
    public var setToken: @Sendable (_ token: String, _ server: String) -> Void

    public static let keychain = SecretStore(
        token: { server in Keychain.read(account(server)).flatMap { String(data: $0, encoding: .utf8) } ?? "" },
        setToken: { token, server in
            if token.isEmpty { Keychain.delete(account(server)) } else { Keychain.write(Data(token.utf8), to: account(server)) }
        }
    )

    /// "access-token" is the account older versions used for their one token.
    private static func account(_ server: String) -> String {
        server.isEmpty ? "access-token" : "access-token \(server)"
    }

    /// `initial` is the token not yet tied to a server.
    public static func inMemory(_ initial: String = "") -> SecretStore {
        let box = TokenBox(initial.isEmpty ? [:] : ["": initial])
        return SecretStore(token: { box.value[$0] ?? "" },
                           setToken: { token, server in box.value[server] = token.isEmpty ? nil : token })
    }
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [String: String]
    init(_ value: [String: String]) { _value = value }
    var value: [String: String] {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
