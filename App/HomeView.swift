import BridgeCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: BridgeModel
    @AppStorage("lastHost") private var hostName = ""

    var body: some View {
        Form {
            if let notice = model.notice {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text(notice)
                        Spacer()
                        Button("Dismiss") { model.dismissNotice() }
                    }
                }
            }

            Section("Control another Mac") {
                TextField("Device name", text: $hostName, prompt: Text("e.g. studio"))
                    .onSubmit(connect)
                HStack {
                    controllerStatus
                    Spacer()
                    if case .calling = model.controllerStatus {
                        Button("Cancel") { model.disconnect() }
                    } else {
                        Button("Connect", action: connect)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canConnect)
                    }
                }
            }

            Section("This Mac") {
                Toggle("Allow this Mac to be controlled", isOn: $model.allowsControl)
                if model.allowsControl {
                    PermissionRow(
                        title: "Screen Recording",
                        detail: "Needed to show this screen to the other Mac.",
                        granted: model.hasScreenPermission,
                        request: model.requestScreenPermission,
                        settingsPane: "Privacy_ScreenCapture"
                    )
                    PermissionRow(
                        title: "Accessibility",
                        detail: "Needed to move the pointer and type.",
                        granted: model.hasInputPermission,
                        request: model.requestInputPermission,
                        settingsPane: "Privacy_Accessibility"
                    )
                    if case let .sharing(peer) = model.hostStatus {
                        Label("\(peer) is controlling this Mac", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Connection") {
                TextField("Server", text: $model.serverURL, prompt: Text("wss://bridge.example.com"))
                TextField("This device's name", text: $model.deviceName)
                if !model.isDeviceNameValid {
                    Text("Use letters, digits, - and _ only (up to 64).")
                        .font(.callout).foregroundStyle(.red)
                }
                HStack {
                    signalingStatus
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
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var canConnect: Bool {
        model.signalingStatus == .online
            && BridgeModel.isValidDeviceName(hostName.trimmingCharacters(in: .whitespaces))
            && hostName != model.deviceName
    }

    private func connect() {
        guard canConnect else { return }
        model.connect(to: hostName)
    }

    @ViewBuilder private var controllerStatus: some View {
        switch model.controllerStatus {
        case .idle:
            Text(model.signalingStatus == .online ? "Ready" : "Go online to connect")
                .foregroundStyle(.secondary)
        case let .calling(host):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(host)…")
            }
        case let .connected(host):
            Text("Connected to \(host)")
        case let .failed(reason):
            Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var signalingStatus: some View {
        switch model.signalingStatus {
        case .offline: Label("Offline", systemImage: "circle").foregroundStyle(.secondary)
        case .connecting: Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.orange)
        case .online: Label("Online as \(model.deviceName)", systemImage: "circle.fill").foregroundStyle(.green)
        }
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
