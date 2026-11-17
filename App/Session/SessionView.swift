import BridgeCore
import SwiftUI

/// How the remote screen is fitted into the window.
enum ViewMode: String, CaseIterable, Identifiable {
    case fit, fill, actual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit to Window"
        case .fill: return "Fill Window"
        case .actual: return "Actual Size"
        }
    }

    var symbol: String {
        switch self {
        case .fit: return "arrow.down.right.and.arrow.up.left.rectangle"
        case .fill: return "arrow.up.left.and.arrow.down.right.rectangle"
        case .actual: return "1.magnifyingglass"
        }
    }
}

/// The remote Mac's screen, with input going to it while the pointer is over it.
struct SessionView: View {
    @EnvironmentObject private var model: BridgeModel
    let video: RemoteVideo
    let host: PairedDevice?
    @State private var quality = QualityPreset.sharp
    @AppStorage("viewMode") private var viewMode = ViewMode.fit
    @State private var showsStats = false

    private var videoSize: CGSize { model.remoteVideoSize ?? CGSize(width: 16, height: 10) }

    var body: some View {
        ZStack {
            Color.black
            screen
        }
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showsStats.toggle() } label: {
                    ConnectionChip(name: host.map(model.displayName) ?? "MacBridge", stats: model.sessionStats)
                }
                .buttonStyle(.plain)
                .help("Connection details")
                .popover(isPresented: $showsStats, arrowEdge: .bottom) {
                    StatsPanel(stats: model.sessionStats)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                displaysMenu
                viewMenu
                qualityMenu
                actionsMenu
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .help("Full screen. Move the pointer to the top edge to get this toolbar back.")
                Button("Disconnect", systemImage: "xmark.circle.fill") { model.disconnect() }
                    .labelStyle(.titleAndIcon)
                    .help("End the session")
            }
        }
        .onDisappear { Thumbnails.save(from: video, for: host?.id) }
    }

    // MARK: Screen

    private var remote: some View {
        RemoteVideoView(video) { model.setRemoteVideoSize($0) }
            .overlay(InputCaptureView { model.sendInput($0) })
    }

    @ViewBuilder private var screen: some View {
        switch viewMode {
        case .fit:
            remote.aspectRatio(videoSize, contentMode: .fit)
        case .fill:
            GeometryReader { geometry in
                remote
                    .aspectRatio(videoSize, contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        case .actual:
            // One remote pixel on one pixel of this Mac's screen.
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            ScrollView([.horizontal, .vertical]) {
                remote.frame(width: videoSize.width / scale, height: videoSize.height / scale)
            }
        }
    }

    // MARK: Toolbar menus

    @ViewBuilder private var displaysMenu: some View {
        if model.remoteDisplays.count > 1 {
            Menu {
                ForEach(model.remoteDisplays) { display in
                    Button { model.selectDisplay(display) } label: {
                        if display.isCurrent { Image(systemName: "checkmark") }
                        Text("\(display.name)  \(display.pixelWidth) × \(display.pixelHeight)")
                    }
                    .disabled(display.isCurrent)
                }
            } label: {
                Label("Display", systemImage: "display.2")
            }
            .help("Choose which of the other Mac's displays to show")
        } else if model.remoteDisplays.isEmpty {
            // A Mac on an older MacBridge does not say what displays it has.
            Button("Next Display", systemImage: "display.2") { model.sendInput(.nextDisplay) }
                .help("Show the other Mac's next display")
        }
    }

    private var viewMenu: some View {
        Menu {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("View", systemImage: viewMode.symbol)
        }
        .help("Fit shows the whole screen. Fill uses the whole window and may cut the edges. Actual Size shows every pixel.")
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Quality", selection: $quality) {
                Text("Sharp: full detail, 60 fps").tag(QualityPreset.sharp)
                Text("Balanced: 30 fps").tag(QualityPreset.balanced)
                Text("Light: smaller, 15 fps").tag(QualityPreset.light)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Quality", systemImage: "dial.medium")
        }
        .help("Lower the quality on a weak connection")
        .onChange(of: quality) { _, preset in model.sendInput(.quality(preset)) }
    }

    private var actionsMenu: some View {
        Menu {
            Section("Desktops") {
                Button("Previous Desktop", systemImage: "chevron.left") { model.sendShortcut(.previousDesktop) }
                Button("Next Desktop", systemImage: "chevron.right") { model.sendShortcut(.nextDesktop) }
                Button("Mission Control", systemImage: "rectangle.3.group") { model.sendShortcut(.missionControl) }
            }
            Section("Keys this Mac keeps for itself") {
                Button("Spotlight (⌘Space)", systemImage: "magnifyingglass") { model.sendShortcut(.spotlight) }
                Button("Switch App (⌘Tab)", systemImage: "square.on.square") { model.sendShortcut(.appSwitcher) }
            }
            Section {
                Button("Send Clipboard", systemImage: "doc.on.clipboard") {
                    if let text = InputMapping.clipboardText(NSPasteboard.general.string(forType: .string)) {
                        model.sendInput(.clipboard(text: text))
                    }
                }
                Button("Lock Screen", systemImage: "lock") { model.sendShortcut(.lockScreen) }
            }
        } label: {
            Label("Actions", systemImage: "bolt")
        }
        .help("Shortcuts and actions for the other Mac")
    }
}

// MARK: - Connection chip

/// The Mac's name and, once known, how the connection is doing.
struct ConnectionChip: View {
    let name: String
    let stats: SessionStats?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.headline).lineLimit(1)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var color: Color {
        guard let stats, let relayed = stats.isRelayed else { return .secondary }
        if let ms = stats.roundTripMs, ms > 150 { return .orange }
        return relayed ? .orange : .green
    }

    private var detail: String? {
        guard let stats else { return nil }
        var parts: [String] = []
        if let relayed = stats.isRelayed { parts.append(relayed ? "Relayed" : "Direct") }
        if let ms = stats.roundTripMs { parts.append("\(Int(ms.rounded())) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct StatsPanel: View {
    let stats: SessionStats?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if let stats {
                row("Route", stats.isRelayed.map { $0 ? "Through the relay server" : "Direct between the Macs" })
                row("Round trip", stats.roundTripMs.map { "\(Int($0.rounded())) ms" })
                row("Picture", stats.width > 0 ? "\(stats.width) × \(stats.height)" : nil)
                row("Frame rate", "\(Int(stats.framesPerSecond.rounded())) fps")
                row("Bit rate", stats.bitsPerSecond.map(Self.bitRate))
                row("Packets lost", stats.lossPercent.map { String(format: "%.1f %%", $0) })
                row("Video", stats.codec.map { codec in codec + (stats.usesHardware.map { $0 ? ", hardware" : ", software" } ?? "") })
            } else {
                Text("Waiting for the first figures…").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 260, alignment: .leading)
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value ?? "—").monospacedDigit()
        }
    }

    static func bitRate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mbit/s", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbit/s", bitsPerSecond / 1000)
    }
}

// MARK: - Before and after the picture

/// Shown from the click on Connect until the first picture arrives.
struct ConnectingView: View {
    let name: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88).accessibilityHidden(true)
            Text("Connecting to \(name)…").font(.title2.weight(.semibold))
            ProgressView().controlSize(.small)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 640, minHeight: 400)
    }
}

/// Shown when a session could not start or dropped.
struct DroppedView: View {
    let name: String?
    let reason: String
    let reconnect: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 44, weight: .light)).foregroundStyle(.orange)
            Text(reason).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("The other Mac may be asleep, offline, or not allowing control right now.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Back to My Macs", action: close).keyboardShortcut(.cancelAction)
                if let reconnect {
                    Button(name.map { "Reconnect to \($0)" } ?? "Reconnect", action: reconnect)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 640, minHeight: 400)
    }
}
