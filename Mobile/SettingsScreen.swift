import BridgeCore
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: BridgeModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pointerMode") private var pointerModeRaw: String = (UIDevice.current.userInterfaceIdiom == .pad ? PointerMode.direct.rawValue : PointerMode.trackpad.rawValue)
    @AppStorage("qualityPreset") private var qualityRaw: Int = Int(QualityPreset.sharp.rawValue)
    @State private var copied = false
    // Server and token are edited as drafts and applied on Return, on leaving the field, on
    // Go online or on Done: each server keeps its own token, and a half-typed address must
    // not count as a server.
    @State private var serverDraft = ""
    @State private var tokenDraft = ""
    @State private var tokenLoaded = ""
    @FocusState private var focused: Field?
    private enum Field { case server, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $serverDraft, prompt: Text("wss://bridge.example.com"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .focused($focused, equals: .server)
                        .onSubmit(commit)
                    SecureField("Access token", text: $tokenDraft)
                        .focused($focused, equals: .token)
                        .onSubmit(commit)
                    Toggle("Always relay through the server", isOn: $model.forcesRelay)
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
                ToolbarItem(placement: .confirmationAction) { Button("Done") { commit(); dismiss() } }
            }
            .onAppear(perform: load)
            .onDisappear(perform: commit)
            .onChange(of: focused) { old, new in if old != nil, new != old { commit() } }
            // A confirmed pairing link may switch the server while this is open.
            .onChange(of: model.serverURL) { _, _ in if focused == nil { load() } }
        }
    }

    private var draftIsValid: Bool { BridgeModel.parseServerURL(serverDraft) != nil }

    private func load() {
        serverDraft = model.serverURL
        tokenDraft = model.accessToken
        tokenLoaded = model.accessToken
    }

    private func commit() {
        model.applyConnectionSettings(server: serverDraft, token: tokenDraft == tokenLoaded ? nil : tokenDraft)
        load()
    }

    private func commitAndGoOnline() {
        commit()
        model.goOnline()
    }
}
