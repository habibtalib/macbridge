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
                // Set through the binding, not onChange: reading the real state back must not
                // count as another change, which would clear the error just shown.
                Toggle("Open MacBridge at login", isOn: Binding(
                    get: { startsAtLogin },
                    set: { enabled in
                        loginItemError = LoginItem.setEnabled(enabled)
                        startsAtLogin = LoginItem.isEnabled
                    }
                ))
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
    /// The Mac whose right to control this one waits for a yes to be removed.
    @State private var removing: PairedDevice?

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

            if model.hasLid {
                Section {
                    Picker("With the lid closed", selection: $model.lidClosedMode) {
                        Text("Sleep as usual").tag(LidClosedMode.off)
                        Text("Stay reachable on the power adapter").tag(LidClosedMode.onPower)
                        Text("Always stay reachable").tag(LidClosedMode.always)
                    }
                    .disabled(!model.canStayAwakeLidClosed)
                } footer: {
                    if model.canStayAwakeLidClosed {
                        Text("Applies while Allow control is on and this Mac is online. A closed Mac is shown to the other Mac on a virtual display. LidAwake does the holding, and its battery and heat limits still apply. A closed Mac that stays awake in a bag gets hot: \"on the power adapter\" is the safe choice.")
                    } else {
                        Text("Needs LidAwake on this Mac (the lidawake command was not found). macOS only lets an administrator switch off lid-close sleep, and LidAwake holds that permission.")
                    }
                }
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
                        Button("Remove…", role: .destructive) { removing = device }
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
        .alert(removing.map { "Stop \(model.displayName($0)) from controlling this Mac?" } ?? "",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { device in
            Button("Remove", role: .destructive) { model.revokeControl(from: device) }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("A session it has open ends now. To control this Mac again, it needs a new pairing code from here.")
        }
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
    // Server and token are edited as drafts and applied on Return, on leaving the field, on
    // Go online or on closing: each server keeps its own token, and a half-typed address must
    // not count as a server.
    @State private var serverDraft = ""
    @State private var tokenDraft = ""
    @State private var tokenLoaded = ""
    /// The server the fields were filled from: a token typed belongs to it.
    @State private var serverLoaded = ""
    @FocusState private var focused: Field?
    private enum Field { case server, token }

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $serverDraft, prompt: Text("wss://bridge.example.com"))
                    .focused($focused, equals: .server)
                    .onSubmit(commit)
                SecureField("Access token", text: $tokenDraft)
                    .focused($focused, equals: .token)
                    .onSubmit(commit)
                Toggle("Always relay through the server", isOn: $model.forcesRelay)
            } footer: {
                Text("The server only introduces the two Macs. Relaying needs a TURN relay on the server; without one, leave it off. Changes apply the next time this Mac goes online.")
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
                        Button("Go online", action: commitAndGoOnline).disabled(!draftIsValid)
                    } else {
                        Button("Reconnect", action: commitAndGoOnline).disabled(!draftIsValid)
                        Button("Go offline") { model.goOffline() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onDisappear(perform: commit)
        .onChange(of: focused) { old, new in if old != nil, new != old { commit() } }
        // A confirmed pairing link may switch the server while this is open.
        .onChange(of: model.serverURL) { _, _ in if focused == nil { load() } }
    }

    private var draftIsValid: Bool { BridgeModel.parseServerURL(serverDraft) != nil }

    private func load() {
        serverDraft = model.serverURL
        serverLoaded = model.serverURL
        tokenDraft = model.accessToken
        tokenLoaded = model.accessToken
    }

    private func commit() {
        model.applyConnectionSettings(server: serverDraft, token: tokenDraft == tokenLoaded ? nil : tokenDraft,
                                      loadedServer: serverLoaded)
        load()
    }

    private func commitAndGoOnline() {
        commit()
        model.goOnline()
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
