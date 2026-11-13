import BridgeCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: BridgeModel
    @State private var typedCode = ""
    @State private var isEnteringCode = false

    private var isOnline: Bool { model.signalingStatus == .online }

    var body: some View {
        Form {
            if let notice = model.notice {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        Text(notice)
                        Spacer()
                        Button("Dismiss") { model.dismissNotice() }
                    }
                }
            }
            controlSection
            thisMacSection
            connectionSection
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onChange(of: model.paired) { _, _ in
            // A successful pairing closes the code entry.
            if model.pairingStatus == .idle { isEnteringCode = false; typedCode = "" }
        }
    }

    // MARK: - Control another Mac

    private var controlSection: some View {
        Section("Control another Mac") {
            if model.controllable.isEmpty && !isEnteringCode {
                Text("No Macs yet. On the Mac you want to control, open MacBridge and choose Show pairing code.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.controllable) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(DeviceID.grouped(device.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .calling(device) = model.controllerStatus {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.disconnect() }
                    } else {
                        Button("Connect") { model.connect(to: device) }.disabled(!isOnline)
                    }
                }
                .contextMenu {
                    Button("Forget \(device.name)", role: .destructive) { model.forget(device) }
                }
            }
            if case let .failed(reason) = model.controllerStatus {
                Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }

            if isEnteringCode {
                HStack {
                    TextField("Code", text: $typedCode, prompt: Text("XXXX-XXXX-XXXX-XXXX"))
                        .font(.body.monospaced())
                        .onSubmit { model.pair(usingCode: typedCode) }
                    if model.pairingStatus == .waiting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Pair") { model.pair(usingCode: typedCode) }
                            .disabled(typedCode.isEmpty || !isOnline)
                    }
                    Button("Cancel") {
                        model.cancelPairing()
                        isEnteringCode = false
                        typedCode = ""
                    }
                }
                if case let .failed(reason) = model.pairingStatus {
                    Text(reason).font(.callout).foregroundStyle(.red)
                }
            } else {
                Button("Add a Mac…") { isEnteringCode = true }.disabled(!isOnline)
            }
        }
    }

    // MARK: - This Mac

    private var thisMacSection: some View {
        Section("This Mac") {
            Toggle("Allow this Mac to be controlled", isOn: $model.allowsControl)
            if model.allowsControl {
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Needed to show this screen to the other Mac. Reopen MacBridge after allowing it.",
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
                    Label("\(peer.name) is controlling this Mac", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.red)
                }

                ForEach(model.controllers) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("Can control this Mac").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { model.revokeControl(from: device) }
                    }
                }

                if case let .showingCode(code, expires) = model.pairingStatus {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(code)
                            .font(.title2.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        Text("Type this on the other Mac under Add a Mac. Anyone who has this code can control this Mac. It works once and expires \(expires, style: .relative).")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Hide code") { model.cancelPairing() }
                    }
                } else {
                    Button("Show pairing code") { model.showPairingCode() }.disabled(!isOnline)
                }
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("Connection") {
            TextField("Server", text: $model.serverURL, prompt: Text("wss://bridge.example.com"))
            SecureField("Access token", text: $model.accessToken)
            TextField("This Mac's name", text: $model.deviceName)
            LabeledContent("This Mac's ID") {
                Text(DeviceID.grouped(model.deviceID)).font(.body.monospaced()).textSelection(.enabled)
            }
            Toggle("Always relay through the server", isOn: $model.forcesRelay)
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

    @ViewBuilder private var signalingStatus: some View {
        switch model.signalingStatus {
        case .offline: Label("Offline", systemImage: "circle").foregroundStyle(.secondary)
        case .connecting: Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.orange)
        case .online: Label("Online", systemImage: "circle.fill").foregroundStyle(.green)
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
