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
        .defaultSize(width: 860, height: 560)
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
        if let model, model.canGoOnline { model.goOnline() }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        if let video = model.remoteVideo {
            SessionView(video: video)
        } else {
            HomeView()
        }
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
        Divider()
        Button("Open MacBridge") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Toggle("Allow This Mac to Be Controlled", isOn: $model.allowsControl)
        Divider()
        Button("Quit MacBridge") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.signalingStatus {
        case .offline: return "Offline"
        case .connecting: return "Connecting…"
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
