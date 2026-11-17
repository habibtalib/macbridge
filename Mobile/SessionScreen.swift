import BridgeCore
import SwiftUI

/// The Mac's screen, full size, with a small bar of controls on top.
struct SessionScreen: View {
    @EnvironmentObject private var model: BridgeModel
    let video: RemoteVideo
    let host: PairedDevice
    @StateObject private var input: SessionInput
    @State private var quality = QualityPreset.sharp
    @State private var barCollapsed = false
    @State private var showsStats = false
    @State private var note: String?

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
                Text(note).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64)
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if input.keyboardVisible { KeyBar(input: input) }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            input.send = { [weak model] in model?.sendInput($0) }
        }
        .onDisappear {
            Thumbnails.save(from: video, for: host.id)
        }
        .onChange(of: input.mode) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "pointerMode")
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

    private var controlBar: some View {
        HStack(spacing: 4) {
            if !barCollapsed {
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
                Button { model.sendShortcut(.lockScreen) } label: { Label("Lock Screen", systemImage: "lock") }
            }
            Section("Clipboard") {
                Button {
                    if let text = InputMapping.clipboardText(UIPasteboard.general.string) {
                        model.sendInput(.clipboard(text: text))
                        show("Sent to the Mac's clipboard")
                    } else {
                        show("Nothing to send")
                    }
                } label: { Label("Send Clipboard to Mac", systemImage: "arrow.up.doc.on.clipboard") }
                Button {
                    if let text = model.hostClipboardText {
                        UIPasteboard.general.string = text
                        show("Copied from the Mac")
                    } else {
                        show("Nothing copied on the Mac yet")
                    }
                } label: { Label("Get Mac's Clipboard", systemImage: "arrow.down.doc") }
            }
            Picker("Quality", selection: $quality) {
                Text("Sharp").tag(QualityPreset.sharp)
                Text("Balanced").tag(QualityPreset.balanced)
                Text("Light").tag(QualityPreset.light)
            }
            .pickerStyle(.menu)
            Button { showsStats = true } label: { Label("Connection Details", systemImage: "waveform.path.ecg") }
        } label: { barIcon("ellipsis.circle") }
        .accessibilityLabel("More")
        .onChange(of: quality) { _, preset in model.sendInput(.quality(preset)) }
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

    private let modifiers: [(String, WireModifiers)] = [("⌘", .command), ("⌥", .option), ("⌃", .control), ("⇧", .shift)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(modifiers, id: \.0) { title, modifier in
                    key(title, on: input.sticky.contains(modifier)) {
                        if input.sticky.contains(modifier) { input.sticky.remove(modifier) } else { input.sticky.insert(modifier) }
                    }
                    .accessibilityLabel("Hold \(title) for the next key")
                }
                Divider().frame(height: 24)
                key("esc") { input.press(MacKey.escape) }
                key("tab") { input.press(MacKey.tab) }
                key("←") { input.press(MacKey.leftArrow) }
                key("↓") { input.press(MacKey.downArrow) }
                key("↑") { input.press(MacKey.upArrow) }
                key("→") { input.press(MacKey.rightArrow) }
                Divider().frame(height: 24)
                key("⌘C") { input.press(8, holding: .command) }
                key("⌘V") { input.press(9, holding: .command) }
                key("⌘Z") { input.press(6, holding: .command) }
                key("⌘A") { input.press(0, holding: .command) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(.bar)
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
