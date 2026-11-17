import BridgeCore
import SwiftUI

/// This Mac: its address, whether it is online, and whether it can be controlled.
struct ThisMacPanel: View {
    @EnvironmentObject private var model: BridgeModel
    @State private var copied = false

    private var isOnline: Bool { model.signalingStatus == .online }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("This Mac").font(.caption).foregroundStyle(.secondary)
                    Text(model.deviceName).font(.headline).lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Address").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(DeviceID.grouped(model.deviceID))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DeviceID.grouped(model.deviceID), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this Mac's address")
                }
            }

            statusRow
            Divider()

            Toggle(isOn: $model.allowsControl) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow control")
                    Text("Paired Macs can see and use this Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if model.allowsControl {
                if !model.hasScreenPermission || !model.hasInputPermission {
                    SettingsLink {
                        Label(model.hasScreenPermission ? "Accessibility is not allowed" : "Screen Recording is not allowed",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                    }
                    .buttonStyle(.link).foregroundStyle(.orange)
                    .help("Open Settings → Security to allow it")
                }
                if case let .sharing(peer) = model.hostStatus {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(model.displayName(peer)) is controlling this Mac", systemImage: "dot.radiowaves.left.and.right")
                            .font(.callout.weight(.medium)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("End session") { model.endHostSession() }
                    }
                }
                pairing
            }

            Spacer(minLength: 0)
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
                .buttonStyle(.borderless)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 6) {
            switch model.signalingStatus {
            case .online:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Online").foregroundStyle(.secondary)
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting…").foregroundStyle(.secondary)
            case .offline:
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text("Offline").foregroundStyle(.secondary)
                Spacer()
                if model.canGoOnline {
                    Button("Go online") { model.goOnline() }.controlSize(.small)
                } else {
                    SettingsLink { Text("Set up server…") }.controlSize(.small)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var pairing: some View {
        if case let .showingCode(code, expires) = model.pairingStatus {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("Type it on the other Mac. Whoever has it can control this Mac. Works once, expires \(expires, style: .relative).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Hide code") { model.cancelPairing() }.controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Button("Show pairing code") { model.showPairingCode() }
                .disabled(!isOnline)
                .help("Lets another Mac add this one, so it can control it")
        }
    }
}
