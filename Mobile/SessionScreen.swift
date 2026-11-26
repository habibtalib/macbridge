import BridgeCore
import SwiftUI

/// The Mac's screen, full size, with a small bar of controls on top.
struct SessionScreen: View {
    @EnvironmentObject private var model: BridgeModel
    let video: RemoteVideo
    let host: PairedDevice
    @StateObject private var input: SessionInput
    @AppStorage("qualityPreset") private var qualityRaw: Int = Int(QualityPreset.sharp.rawValue)
    @State private var barCollapsed = false
    @State private var showsStats = false
    @State private var note: String?

    private var quality: Binding<QualityPreset> {
        Binding(
            get: { QualityPreset(rawValue: UInt8(qualityRaw)) ?? .sharp },
            set: { qualityRaw = Int($0.rawValue) }
        )
    }

    init(video: RemoteVideo, host: PairedDevice) {
        self.video = video
        self.host = host
        // A big screen is touched like the Mac's own; a phone works better as a trackpad.
        let saved = UserDefaults.standard.string(forKey: "pointerMode").flatMap(PointerMode.init)
        let mode = saved ?? (UIDevice.current.userInterfaceIdiom == .pad ? .direct : .trackpad)
        // The model is not available in init; onAppear points the input at it.
        _input = StateObject(wrappedValue: SessionInput(mode: mode))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TouchSurface(video, input: input) { model.setRemoteVideoSize($0) }
                .ignoresSafeArea(.container)
            controlBar
                .padding(.top, 6)
            if let note {
                Text(note).font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64)
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if input.keyboardVisible {
                KeyBar(input: input, onPasteFromDevice: {
                    if let text = InputMapping.clipboardText(UIPasteboard.general.string) {
                        model.sendInput(.clipboard(text: text))
                        input.press(9, holding: .command)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        show("Pasted from this device")
                    } else {
                        show("Clipboard is empty")
                    }
                })
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            input.send = { [weak model] in model?.sendInput($0) }
            let preset = QualityPreset(rawValue: UInt8(qualityRaw)) ?? .sharp
            if preset != .sharp { model.sendInput(.quality(preset)) }
        }
        .onDisappear {
            Thumbnails.save(from: video, for: host.id)
        }
        .onChange(of: input.mode) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "pointerMode")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            show(mode == .trackpad ? "Trackpad: drag to move, tap to click" : "Touch: tap where you want to click")
        }
        .sheet(isPresented: $showsStats) { StatsSheet(name: model.displayName(host)) }
    }

    private func show(_ text: String) {
        withAnimation { note = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if note == text { withAnimation { note = nil } }
        }
    }

    // MARK: Control bar

    private var healthColor: Color {
        guard let stats = model.sessionStats else { return .secondary }
        if (stats.lossPercent ?? 0) > 2.0 { return .red }
        if let ms = stats.roundTripMs, ms > 150 { return .orange }
        return stats.isRelayed == true ? .orange : .green
    }

    private var controlBar: some View {
        HStack(spacing: 4) {
            if !barCollapsed {
                Button { showsStats = true } label: {
                    HStack(spacing: 5) {
                        Circle().fill(healthColor).frame(width: 7, height: 7)
                        if let ms = model.sessionStats?.roundTripMs {
                            Text("\(Int(ms.rounded()))ms").font(.caption.weight(.semibold)).monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 8).frame(height: 36)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Connection details")

                barButton("Keyboard", input.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard") { input.toggleKeyboard() }
                barButton(input.mode == .trackpad ? "Switch to touch" : "Switch to trackpad",
                          input.mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.tap") {
                    input.mode = input.mode == .trackpad ? .direct : .trackpad
                }
                if input.isZoomed {
                    barButton("Show the whole screen", "arrow.down.right.and.arrow.up.left") { input.resetZoom() }
                }
                if model.remoteDisplays.count > 1 {
                    Menu {
                        ForEach(model.remoteDisplays) { display in
                            Button { model.selectDisplay(display) } label: {
                                Label("\(display.name)  \(display.pixelWidth) × \(display.pixelHeight)", systemImage: display.isCurrent ? "checkmark" : "display")
                            }
                            .disabled(display.isCurrent)
                        }
                    } label: { barIcon("display.2") }
                    .accessibilityLabel("Display")
                }
                moreMenu
                barButton("Disconnect", "xmark.circle.fill", tint: .red) { model.disconnect() }
            }
            barButton(barCollapsed ? "Show controls" : "Hide controls", barCollapsed ? "chevron.left" : "chevron.right") {
                withAnimation(.snappy) { barCollapsed.toggle() }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 10)
    }

    private var moreMenu: some View {
        Menu {
            Section("Desktops") {
                Button { model.sendShortcut(.previousDesktop) } label: { Label("Previous Desktop", systemImage: "chevron.left") }
                Button { model.sendShortcut(.nextDesktop) } label: { Label("Next Desktop", systemImage: "chevron.right") }
                Button { model.sendShortcut(.missionControl) } label: { Label("Mission Control", systemImage: "rectangle.3.group") }
            }
            Section("Mac") {
                Button { model.sendShortcut(.spotlight) } label: { Label("Spotlight", systemImage: "magnifyingglass") }
                Button { model.sendShortcut(.appSwitcher) } label: { Label("Switch App", systemImage: "square.on.square") }
                Button {
                    if let data = video.thumbnailJPEG(maxWidth: 4096), let image = UIImage(data: data) {
                        UIPasteboard.general.image = image
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        show("Screenshot copied to clipboard")
                    } else {
                        show("No frame available yet")
                    }
                } label: { Label("Copy Screenshot", systemImage: "camera") }
                Button { model.sendShortcut(.lockScreen) } label: { Label("Lock Screen", systemImage: "lock") }
            }
            Section("Clipboard") {
                Button {
                    if let text = InputMapping.clipboardText(UIPasteboard.general.string) {
                        model.sendInput(.clipboard(text: text))
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        show("Sent to the Mac's clipboard")
                    } else {
                        show("Nothing to send")
                    }
                } label: { Label("Send Clipboard to Mac", systemImage: "arrow.up.doc.on.clipboard") }
                Button {
                    if let text = model.hostClipboardText {
                        UIPasteboard.general.string = text
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        show("Copied from the Mac")
                    } else {
                        show("Nothing copied on the Mac yet")
                    }
                } label: { Label("Get Mac's Clipboard", systemImage: "arrow.down.doc") }
            }
            Picker("Quality", selection: quality) {
                Text("Sharp").tag(QualityPreset.sharp)
                Text("Balanced").tag(QualityPreset.balanced)
                Text("Light").tag(QualityPreset.light)
            }
            .pickerStyle(.menu)
            Button { showsStats = true } label: { Label("Connection Details", systemImage: "waveform.path.ecg") }
        } label: { barIcon("ellipsis.circle") }
        .accessibilityLabel("More")
        .onChange(of: qualityRaw) { _, raw in
            let preset = QualityPreset(rawValue: UInt8(raw)) ?? .sharp
            model.sendInput(.quality(preset))
            show(preset == .sharp ? "Quality: Sharp" : preset == .balanced ? "Quality: Balanced" : "Quality: Light")
        }
    }

    private func barIcon(_ symbol: String, tint: Color = .primary) -> some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(tint)
            .frame(width: 42, height: 40).contentShape(Rectangle())
    }

    private func barButton(_ label: String, _ symbol: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) { barIcon(symbol, tint: tint) }
            .accessibilityLabel(label)
    }
}

/// Keys the on-screen keyboard does not have, shown above it.
private struct KeyBar: View {
    @ObservedObject var input: SessionInput
    let onPasteFromDevice: () -> Void

    private let modifiers: [(String, WireModifiers)] = [("⌘", .command), ("⌥", .option), ("⌃", .control), ("⇧", .shift)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(modifiers, id: \.0) { title, modifier in
                    key(title, on: input.sticky.contains(modifier)) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if input.sticky.contains(modifier) { input.sticky.remove(modifier) } else { input.sticky.insert(modifier) }
                    }
                    .accessibilityLabel("Hold \(title) for the next key")
                }
                Divider().frame(height: 24)
                key("esc") { tap(MacKey.escape) }
                key("tab") { tap(MacKey.tab) }
                key("⌫") { tap(MacKey.delete) }
                key("↩") { tap(MacKey.returnKey) }
                key("←") { tap(MacKey.leftArrow) }
                key("↓") { tap(MacKey.downArrow) }
                key("↑") { tap(MacKey.upArrow) }
                key("→") { tap(MacKey.rightArrow) }
                Divider().frame(height: 24)
                Button(action: onPasteFromDevice) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15, weight: .medium))
                        .frame(minWidth: 40, minHeight: 36).padding(.horizontal, 4)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste from this device")
                key("⌃C") { tap(8, holding: .control) }
                key("⌘C") { tap(8, holding: .command) }
                key("⌘V") { tap(9, holding: .command) }
                key("⌘Z") { tap(6, holding: .command) }
                key("⌘A") { tap(0, holding: .command) }
                key("⌘W") { tap(13, holding: .command) }
                key("⌘T") { tap(17, holding: .command) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func tap(_ keyCode: UInt16, holding: WireModifiers = []) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        input.press(keyCode, holding: holding)
    }

    private func key(_ title: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .medium, design: .rounded))
                .frame(minWidth: 40, minHeight: 36).padding(.horizontal, 4)
                .background(on ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct StatsSheet: View {
    @EnvironmentObject private var model: BridgeModel
    @Environment(\.dismiss) private var dismiss
    let name: String

    var body: some View {
        NavigationStack {
            List {
                if let stats = model.sessionStats {
                    row("Route", stats.isRelayed.map { $0 ? "Through the relay server" : "Direct" })
                    row("Round trip", stats.roundTripMs.map { "\(Int($0.rounded())) ms" })
                    row("Picture", stats.width > 0 ? "\(stats.width) × \(stats.height)" : nil)
                    row("Frame rate", "\(Int(stats.framesPerSecond.rounded())) fps")
                    row("Bit rate", stats.bitsPerSecond.map { $0 >= 1_000_000 ? String(format: "%.1f Mbit/s", $0 / 1_000_000) : String(format: "%.0f kbit/s", $0 / 1000) })
                    row("Packets lost", stats.lossPercent.map { String(format: "%.1f %%", $0) })
                    row("Video", stats.codec.map { $0 + (stats.usesHardware.map { $0 ? ", hardware" : ", software" } ?? "") })
                } else {
                    Text("Waiting for the first figures…").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) { Text(value ?? "—").monospacedDigit() }
    }
}
