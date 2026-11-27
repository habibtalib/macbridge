import BridgeCore
import SwiftUI

@main
struct MacBridgeMobileApp: App {
    @StateObject private var launch = MobileLaunch()

    var body: some Scene {
        WindowGroup {
            if let model = launch.model {
                RootScreen().environmentObject(model)
                    // The Mac's pairing QR code read with the Camera app.
                    .onOpenURL { url in
                        if let link = PairingLink(url.absoluteString) { model.pair(using: link) }
                    }
            } else {
                ContentUnavailableView("MacBridge could not read its key",
                                       systemImage: "key.slash",
                                       description: Text("Unlock the device once after a restart, then open MacBridge again."))
            }
        }
    }
}

@MainActor
final class MobileLaunch: ObservableObject {
    /// Nil if the identity key could not be loaded from the keychain.
    let model: BridgeModel?

    init() {
        let firstRun = UserDefaults.standard.string(forKey: "deviceName") == nil
        model = (try? Identity.loadOrCreate()).map { BridgeModel(identity: $0) }
        if firstRun { model?.deviceName = BridgeModel.defaultDeviceName(from: UIDevice.current.name) }
        if let model, model.hasSomewhereToGo { model.goOnline() }
    }
}

struct RootScreen: View {
    @EnvironmentObject private var model: BridgeModel
    @Environment(\.scenePhase) private var phase
    /// A session that iOS ended by putting the app in the background.
    @State private var interrupted: PairedDevice?

    var body: some View {
        Group {
            switch model.controllerStatus {
            case .idle:
                HomeScreen()
            case let .calling(host), let .connected(host):
                if let video = model.remoteVideo {
                    SessionScreen(video: video, host: host)
                } else {
                    // A new host starts a new timer.
                    ConnectingScreen(name: model.displayName(host)) { model.disconnect() }
                        .id(host.id)
                }
            case let .failed(reason):
                DroppedScreen(name: model.lastHost.map(model.displayName), reason: reason,
                              reconnect: model.lastHost != nil && model.signalingStatus == .online ? { model.reconnect() } : nil,
                              close: { model.dismissFailure() })
            }
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .background:
                // iOS stops the app in the background; end the session, or the call still
                // being made, cleanly instead of letting it hang.
                switch model.controllerStatus {
                case let .connected(host), let .calling(host):
                    interrupted = host
                    model.disconnect()
                case .idle, .failed:
                    // A call still waiting for the server would start in the background.
                    if model.hostAwaitingServer != nil { model.disconnect() }
                }
            case .active:
                // A socket left in the background is often dead: check it, or reconnect without backoff.
                model.resumeConnection()
                model.refreshPresence()
            default:
                break
            }
        }
        // The screen stays on while a Mac is being controlled: nobody touches this one meanwhile.
        .onChange(of: model.controllerStatus, initial: true) { _, status in
            switch status {
            case .calling, .connected: UIApplication.shared.isIdleTimerDisabled = true
            case .idle, .failed: UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .alert("Session ended", isPresented: Binding(get: { interrupted != nil && phase == .active }, set: { if !$0 { interrupted = nil } })) {
            Button("Reconnect") {
                // Back from the background the server connection may still be coming back:
                // the call waits for it.
                if let host = interrupted { model.connect(to: host) }
                interrupted = nil
            }
            Button("Not now", role: .cancel) { interrupted = nil }
        } message: {
            Text("The session with \(interrupted.map(model.displayName) ?? "the Mac") ended when MacBridge went to the background.")
        }
        // A pairing link may come from anyone: switching to the server it names needs a yes.
        // HomeScreen shows the same question inline, in case this alert cannot be presented.
        .alert(model.pairingStatus.serverToConfirm?.title ?? "", isPresented: Binding(get: { model.pairingStatus.serverToConfirm != nil }, set: { _ in })) {
            // Each button settles the status, which closes the alert.
            Button("Use \(model.pairingStatus.serverToConfirm?.host ?? "")") { model.confirmServerSwitch() }
            Button("Cancel", role: .cancel) { model.cancelPairing() }
        } message: {
            Text(model.pairingStatus.serverToConfirm?.message ?? "")
        }
    }
}

struct ConnectingScreen: View {
    let name: String
    let cancel: () -> Void
    @State private var started = Date()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer").font(.system(size: 52, weight: .light)).foregroundStyle(.secondary)
            Text("Connecting to \(name)…").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ProgressView()
                Text(started, style: .timer).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Cancel", action: cancel).buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DroppedScreen: View {
    let name: String?
    let reason: String
    let reconnect: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 52, weight: .light)).foregroundStyle(.orange)
            Text(reason).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("The Mac may be asleep, offline, or not allowing control right now.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let reconnect {
                Button(name.map { "Reconnect to \($0)" } ?? "Reconnect", action: reconnect).buttonStyle(.borderedProminent)
            }
            Button("Back to My Macs", action: close).buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pictures of each Mac's screen from the last session.
enum Thumbnails {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbnails", isDirectory: true)
    }

    static func url(for deviceID: String) -> URL { folder.appendingPathComponent("\(deviceID).jpg") }

    /// Read from disk once per picture, not on every redraw of a card.
    @MainActor private static var cache: [String: UIImage?] = [:]

    @MainActor static func image(for deviceID: String) -> UIImage? {
        if let cached = cache[deviceID] { return cached }
        let image = UIImage(contentsOfFile: url(for: deviceID).path)
        cache[deviceID] = .some(image)
        return image
    }

    @MainActor static func save(from video: RemoteVideo, for deviceID: String?) {
        guard let deviceID, let data = video.thumbnailJPEG() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(for: deviceID), options: .atomic)
        cache[deviceID] = nil
        NotificationCenter.default.post(name: changed, object: deviceID)
    }

    /// Posted with the device ID as object when its picture was replaced.
    static let changed = Notification.Name("MacBridge.thumbnailChanged")
}

/// The question to ask while a pairing link waits for a yes to use its server.
struct ServerConfirmation {
    let host: String
    let title: String
    let message: String
}

extension BridgeModel.PairingStatus {
    var serverToConfirm: ServerConfirmation? {
        guard case let .confirmServer(server, sendsToken) = self else { return nil }
        let host = URL(string: server)?.host ?? server
        return sendsToken
            ? ServerConfirmation(host: host, title: "Use this server?",
                                 message: "This pairing code is for the server \(host). Use this server with your access token only if you trust it.")
            : ServerConfirmation(host: host, title: "Use another server?",
                                 message: "This pairing code is for the server \(host), not the one set in Settings. Switch only if you trust it. Your access token stays with the current server.")
    }
}
