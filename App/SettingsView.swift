import BridgeCore
import SwiftUI

/// ⌘, : everything that is set once and then left alone.
struct SettingsView: View {
    /// For layout snapshots: show one tab's content on its own.
    var only: String?

    var body: some View {
        switch only {
        case "general": GeneralSettings()
        case "security": SecuritySettings()
        case "connection": ConnectionSettings()
        default: tabs
        }
    }

    private var tabs: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SecuritySettings().tabItem { Label("Security", systemImage: "lock.shield") }
            ConnectionSettings().tabItem { Label("Connection", systemImage: "network") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var model: BridgeModel
    @State private var startsAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                TextField("This Mac's name", text: $model.deviceName)
                LabeledContent("Address") {
                    Text(DeviceID.grouped(model.deviceID)).font(.body.monospaced()).textSelection(.enabled)
                }
            } footer: {
                Text("The name is what other Macs see when they pair with this one.")
            }
            Section {
                Toggle("Open MacBridge at login", isOn: $startsAtLogin)
                    .onChange(of: startsAtLogin) { _, enabled in
                        loginItemError = LoginItem.setEnabled(enabled)
                        startsAtLogin = LoginItem.isEnabled
                    }
                if let loginItemError {
                    Text(loginItemError).font(.callout).foregroundStyle(.red)
                }
            } footer: {
                Text("A Mac that should be reachable at any time needs this. After a restart it is reachable once someone has logged in.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SecuritySettings: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        Form {
            Section {
                Toggle("Allow this Mac to be controlled", isOn: $model.allowsControl)
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Needed to show this screen to the other Mac. Reopen MacBridge after allowing it.",
                    granted: model.hasScreenPermission,
                    request: model.requestScreenPermission,
                    settingsPane: "Privacy_ScreenCapture"
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Needed to move the pointer and type, and to send Control-arrow shortcuts to another Mac.",
                    granted: model.hasInputPermission,
                    request: model.requestInputPermission,
                    settingsPane: "Privacy_Accessibility"
                )
            } footer: {
                Text("This Mac stays awake while it can be controlled.")
            }

            Section("Macs that can control this Mac") {
                if model.controllers.isEmpty {
                    Text("None. Show a pairing code in the main window to add one.").foregroundStyle(.secondary)
                }
                ForEach(model.controllers) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName(device))
                            Text(DeviceID.grouped(device.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Ask first", isOn: Binding(
                            get: { model.meta[device.id]?.asksFirst ?? false },
                            set: { model.setAsksFirst(device, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Show Accept and Decline on this Mac before \(model.displayName(device)) can connect. Leave off for a Mac nobody sits at.")
                        Button("Remove", role: .destructive) { model.revokeControl(from: device) }
                    }
                }
            }

            if !model.sessionLog.isEmpty {
                Section("Recent sessions") {
                    ForEach(model.sessionLog.prefix(10)) { entry in
                        LabeledContent(entry.deviceName) {
                            Text(Self.describe(entry)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPermissions() }
    }

    private static func describe(_ entry: SessionLogEntry) -> String {
        let start = entry.started.formatted(date: .abbreviated, time: .shortened)
        guard let ended = entry.ended else { return "\(start), in progress" }
        let duration = Duration.seconds(ended.timeIntervalSince(entry.started).rounded())
        return "\(start), \(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))"
    }
}

private struct ConnectionSettings: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $model.serverURL, prompt: Text("wss://bridge.example.com"))
                SecureField("Access token", text: $model.accessToken)
                Toggle("Always relay through the server", isOn: $model.forcesRelay)
            } footer: {
                Text("The server only introduces the two Macs. Changes apply the next time this Mac goes online.")
            }
            Section {
                HStack {
                    switch model.signalingStatus {
                    case .offline: Label("Offline", systemImage: "circle").foregroundStyle(.secondary)
                    case .connecting: Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.orange)
                    case .online: Label("Online", systemImage: "circle.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    if model.signalingStatus == .offline {
                        Button("Go online") { model.goOnline() }.disabled(!model.canGoOnline)
                    } else {
                        Button("Reconnect") { model.goOnline() }.disabled(!model.canGoOnline)
                        Button("Go offline") { model.goOffline() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    let settingsPane: String

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Allow…") {
                    request()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
