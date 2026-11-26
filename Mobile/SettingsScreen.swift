import BridgeCore
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: BridgeModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pointerMode") private var pointerModeRaw: String = (UIDevice.current.userInterfaceIdiom == .pad ? PointerMode.direct.rawValue : PointerMode.trackpad.rawValue)
    @AppStorage("qualityPreset") private var qualityRaw: Int = Int(QualityPreset.sharp.rawValue)
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $model.serverURL, prompt: Text("wss://bridge.example.com"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Access token", text: $model.accessToken)
                    Toggle("Always relay through the server", isOn: $model.forcesRelay)
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
                        }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Use the same server as your Macs. If it is on a private network such as Tailscale, this device has to be connected to that network too.")
                }

                Section {
                    Picker("Default pointer", selection: $pointerModeRaw) {
                        Text("Trackpad").tag(PointerMode.trackpad.rawValue)
                        Text("Touch").tag(PointerMode.direct.rawValue)
                    }
                    Picker("Default quality", selection: $qualityRaw) {
                        Text("Sharp (60 fps)").tag(Int(QualityPreset.sharp.rawValue))
                        Text("Balanced (30 fps)").tag(Int(QualityPreset.balanced.rawValue))
                        Text("Light (15 fps)").tag(Int(QualityPreset.light.rawValue))
                    }
                } header: {
                    Text("Session Defaults")
                } footer: {
                    Text("You can also switch pointer mode and quality any time during a session.")
                }

                Section {
                    TextField("Name", text: $model.deviceName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        UIPasteboard.general.string = DeviceID.grouped(model.deviceID)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        LabeledContent("Address") {
                            Text(copied ? "Copied" : DeviceID.grouped(model.deviceID)).font(.footnote.monospaced())
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("This device")
                } footer: {
                    Text("An iPhone or iPad can control a Mac, but cannot be controlled: iOS does not allow it.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
