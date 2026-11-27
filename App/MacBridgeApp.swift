import BridgeCore
import ServiceManagement
import SwiftUI

@main
struct MacBridgeApp: App {
    @StateObject private var launch = Launch()

    var body: some Scene {
        Window("MacBridge", id: "main") {
            if let model = launch.model {
                RootView().environmentObject(model)
            } else {
                KeychainErrorView()
            }
        }
        .defaultSize(width: 960, height: 620)
        .commands {
            // The remote screen takes ⌘ shortcuts while it has focus, so the
            // local "New Window" item would only get in the way.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            if let model = launch.model {
                SettingsView().environmentObject(model)
            }
        }

        // Keeps the app running, and visibly so, with the window closed:
        // a Mac that can be controlled should always show that it can.
        MenuBarExtra {
            if let model = launch.model {
                MenuBarContent().environmentObject(model)
            } else {
                Button("Quit MacBridge") { NSApplication.shared.terminate(nil) }
            }
        } label: {
            MenuBarIcon(model: launch.model)
        }
    }
}

@MainActor
final class Launch: ObservableObject {
    /// Nil if the identity key could not be loaded from the keychain.
    let model: BridgeModel?
    private var panels: HostPanels?

    init() {
        if Snapshot.isActive {
            let sample = Snapshot.sampleModel()
            model = sample
            DispatchQueue.main.async { Snapshot.run(model: sample) }
            return
        }
        model = (try? Identity.loadOrCreate()).map { BridgeModel(identity: $0) }
        // Online from launch, window or not: after a login-item start nobody
        // is there to click anything.
        if let model, model.hasSomewhereToGo { model.goOnline() }
        panels = model.map(HostPanels.init)
        if let model {
            // Neither a session, with keys the controller holds down, nor a hold on
            // lid-close sleep may outlive the app.
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { model.prepareForQuit() }
            }
            // The menu bar menu shows which Macs are online: ask again whenever it opens. Menus of
            // the main menu bar have a supermenu; the status item's menu has none.
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                guard let menu = note.object as? NSMenu, menu.supermenu == nil, menu !== NSApp.mainMenu else { return }
                MainActor.assumeIsolated { model.refreshPresence() }
            }
        }
    }
}

extension BridgeModel {
    /// The Mac this one is calling or controlling, if any.
    var sessionHost: PairedDevice? {
        switch controllerStatus {
        case let .calling(host), let .connected(host): return host
        case .idle, .failed: return nil
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        content.background(SessionCloseGuardView(model: model, status: model.controllerStatus))
    }

    @ViewBuilder private var content: some View {
        switch model.controllerStatus {
        case .idle:
            HomeView()
        case let .calling(host), let .connected(host):
            if let video = model.remoteVideo {
                SessionView(video: video, host: host)
            } else {
                // A new host starts a new timer.
                ConnectingView(name: model.displayName(host)) { model.disconnect() }
                    .id(host.id)
            }
        case let .failed(reason):
            DroppedView(
                name: model.lastHost.map(model.displayName), reason: reason,
                reconnect: model.lastHost != nil && model.signalingStatus == .online ? { model.reconnect() } : nil,
                close: { model.dismissFailure() }
            )
        }
    }
}

/// Puts `SessionCloseGuard` on the window this view is in.
private struct SessionCloseGuardView: NSViewRepresentable {
    let model: BridgeModel
    /// Unused here, but a change runs updateNSView, which puts the guard back if needed.
    let status: BridgeModel.ControllerStatus

    func makeCoordinator() -> SessionCloseGuard { SessionCloseGuard(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowWatcher()
        view.onWindow = { [weak guardian = context.coordinator] window in guardian?.attach(to: window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // SwiftUI may set its own delegate again.
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: NSView, coordinator: SessionCloseGuard) {
        coordinator.detach()
    }

    private final class WindowWatcher: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// Closing the window in the middle of a session would leave the session running with nothing
/// on screen: ask first. Stands in as the window's delegate and passes everything else on to
/// the delegate SwiftUI set.
@MainActor
final class SessionCloseGuard: NSObject, NSWindowDelegate {
    private let model: BridgeModel
    private weak var window: NSWindow?
    private var original: NSWindowDelegate?
    private var keyObserver: NSObjectProtocol?

    init(model: BridgeModel) { self.model = model }

    /// Becomes the window's delegate, again if SwiftUI has set its own since.
    func attach(to window: NSWindow?) {
        guard let window, window.delegate !== self else { return }
        if window !== self.window {
            detach()
            self.window = window
            // SwiftUI may replace the delegate without this view being updated: look again
            // whenever the window comes to the front.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.attach(to: window) }
            }
        }
        original = window.delegate
        window.delegate = self
    }

    func detach() {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        if let window, window.delegate === self { window.delegate = original }
        window = nil
        original = nil
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let host = model.sessionHost else { return original?.windowShouldClose?(sender) ?? true }
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Disconnect from \(model.displayName(host))?"
        alert.informativeText = "Closing the window ends the session."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard response == .alertFirstButtonReturn, let self, let sender else { return }
            self.model.disconnect()
            sender.performClose(nil)
        }
        return false
    }
}

private struct MenuBarIcon: View {
    let model: BridgeModel?

    var body: some View {
        if let model {
            Icon(model: model)
        } else {
            Image(systemName: "rectangle.on.rectangle.slash")
        }
    }

    private struct Icon: View {
        @ObservedObject var model: BridgeModel

        var body: some View {
            if case .sharing = model.hostStatus {
                // Unmissable while someone is in control.
                Image(systemName: "dot.radiowaves.left.and.right")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "rectangle.on.rectangle")
            }
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: BridgeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.hostStatus {
        case let .sharing(peer):
            Text("\(peer.name) is controlling this Mac")
            Button("End Session") { model.endHostSession() }
        case .idle:
            Text(statusLine)
        }
        switch model.controllerStatus {
        case let .connected(host):
            Text("Connected to \(model.displayName(host))")
            Button("Disconnect") { model.disconnect() }
        case let .calling(host):
            Text("Connecting to \(model.displayName(host))…")
            Button("Cancel") { model.disconnect() }
        case .idle, .failed:
            if let waiting = model.hostAwaitingServer {
                Text("Connecting to \(model.displayName(waiting))… (waiting for server)")
                Button("Cancel") { model.disconnect() }
            }
        }
        Divider()
        Button("Open MacBridge", action: showWindow)
        if !model.controllable.isEmpty {
            Menu("Connect to") {
                ForEach(model.controllableSorted) { device in
                    Button {
                        showWindow()
                        // The Mac already on screen is only brought forward.
                        if model.sessionHost?.id != device.id { model.connect(to: device) }
                    } label: {
                        // Menus draw text only: the dot says what the server or this network last reported.
                        Text((model.presence[device.id] == true ? "● " : model.presence[device.id] == false ? "○ " : "") + model.displayName(device))
                    }
                }
            }
            .disabled(!model.isReachable)
        }
        Toggle("Allow This Mac to Be Controlled", isOn: $model.allowsControl)
        Button("Copy This Mac's Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(DeviceID.grouped(model.deviceID), forType: .string)
        }
        if model.allowsControl, model.signalingStatus == .online {
            Button("Show Pairing Code") {
                showWindow()
                model.showPairingCode()
            }
        }
        Divider()
        Button("Quit MacBridge") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var statusLine: String {
        switch model.signalingStatus {
        case .offline where model.isOnLocalNetwork:
            return model.allowsControl ? "Local network only, can be controlled" : "Local network only"
        case .offline: return "Offline"
        case .connecting: return model.isOnLocalNetwork ? "Local network; connecting to server…" : "Connecting…"
        case .online: return model.allowsControl ? "Online, can be controlled" : "Online"
        }
    }
}

/// Start MacBridge when the user logs in.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an explanation if the change did not go through.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct KeychainErrorView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash").font(.system(size: 36)).foregroundStyle(.red)
            Text("MacBridge could not read its key from the keychain.")
                .font(.headline)
            Text("Unlock the login keychain and allow MacBridge access, then reopen the app. A new key is not created automatically, because that would unpair every device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(32)
        .frame(width: 420)
    }
}
