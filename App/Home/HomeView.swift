import BridgeCore
import SwiftUI

/// The main window: this Mac on the left, the Macs it can control on the right.
struct HomeView: View {
    @EnvironmentObject private var model: BridgeModel
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            ThisMacPanel()
                .frame(width: 264)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                banners
                ConnectBar(query: $query)
                DeviceGrid(query: query)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            model.refreshPresence()
        }
        // The dots on the tiles: asked while this screen is showing.
        .task(id: model.signalingStatus) {
            while !Task.isCancelled {
                model.refreshPresence()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: model.paired) { _, _ in model.refreshPresence() }
    }

    @ViewBuilder private var banners: some View {
        if let notice = model.notice {
            Banner(text: notice, symbol: "info.circle.fill", tint: .blue) { model.dismissNotice() }
        }
    }
}

private struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let dismiss {
                Button("Dismiss", action: dismiss).buttonStyle(.link)
            }
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Connect bar

/// One field for everything that starts a connection: a paired Mac's name or
/// address, or a pairing code from a Mac that is not paired yet.
private struct ConnectBar: View {
    @EnvironmentObject private var model: BridgeModel
    @Binding var query: String
    @FocusState private var focused: Bool

    private var input: ConnectInput {
        ConnectInput.parse(query, devices: model.controllable, names: model.displayNames)
    }
    private var isOnline: Bool { model.signalingStatus == .online }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect to a Mac").font(.headline)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Name, address or pairing code", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit(submit)
                    if !query.isEmpty {
                        Button { query = ""; model.cancelPairing() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear")
                            .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.12)))

                if model.pairingStatus == .waiting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: submit) {
                        Text(buttonTitle).frame(minWidth: 64)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
            if let hint {
                Text(hint.text).font(.callout).foregroundStyle(hint.isError ? Color.red : Color.secondary)
            }
        }
        .onChange(of: model.paired) { _, _ in
            // A finished pairing clears the code from the field.
            if model.pairingStatus == .idle, case .pairingCode = input { query = "" }
        }
    }

    private var buttonTitle: String {
        if case .pairingCode = input { return "Pair" }
        return "Connect"
    }

    private var canSubmit: Bool {
        guard isOnline else { return false }
        switch input {
        case .device, .pairingCode: return true
        case .empty, .search: return false
        }
    }

    private var hint: (text: String, isError: Bool)? {
        if case let .failed(reason) = model.pairingStatus { return (reason, true) }
        if !isOnline, !query.isEmpty { return ("This Mac is offline. Go online first.", true) }
        switch input {
        case let .device(device): return ("Return connects to \(model.displayName(device)).", false)
        case .pairingCode: return ("That looks like a pairing code. Pair to add the Mac that shows it.", false)
        case .search:
            return ConnectInput.filter(model.controllable, query, names: model.displayNames).isEmpty
                ? ("No paired Mac matches. To add one, type the pairing code it shows.", false) : nil
        case .empty: return nil
        }
    }

    private func submit() {
        guard isOnline else { return }
        switch input {
        case let .device(device):
            model.connect(to: device)
            query = ""
        case let .pairingCode(code):
            model.pair(usingCode: code)
        case .empty, .search:
            break
        }
    }
}

// MARK: - Devices

/// Tiles in as many columns as fit, each between `minWidth` and `maxWidth` wide, left-aligned;
/// each row is as tall as its tallest tile.
struct TileGrid: Layout {
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var spacing: CGFloat

    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        // SwiftUI also measures with an unbounded width (.infinity) or none.
        guard width.isFinite, width > 0 else { return (1, minWidth) }
        let count = max(1, Int((width + spacing) / (minWidth + spacing)))
        let fitted = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (count, min(maxWidth, max(0, fitted)))
    }

    private func rowHeights(_ subviews: Subviews, count: Int, width: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: count).map { start in
            subviews[start..<min(start + count, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minWidth
        let (count, width) = columns(for: available)
        let heights = rowHeights(subviews, count: count, width: width)
        let height = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: max(available, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (count, width) = columns(for: bounds.width)
        let heights = rowHeights(subviews, count: count, width: width)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<count {
                let index = row * count + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (width + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: width, height: height))
            }
            y += height + spacing
        }
    }
}

private enum DeviceFilter: String, CaseIterable, Identifiable {
    case all, online, favourites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .online: return "Online"
        case .favourites: return "Favourites"
        }
    }
}

private struct DeviceGrid: View {
    @EnvironmentObject private var model: BridgeModel
    let query: String
    @State private var filter: DeviceFilter = .all
    /// Tile order, by device ID. Worked out again when the filter, the search or the paired Macs
    /// change, not on every presence answer: a tile must not move away from under the pointer.
    @State private var order: [String] = []
    // Kept here, not in the tile: a tile can leave the grid (its Mac went offline under the
    // Online filter) while its question is open.
    @State private var renaming: PairedDevice?
    @State private var forgetting: PairedDevice?
    @State private var newName = ""

    private var filteredByQuery: [PairedDevice] {
        ConnectInput.filter(model.controllableSorted, query, names: model.displayNames)
    }

    private var onlineCount: Int {
        model.controllable.filter { model.presence[$0.id] == true }.count
    }

    private var favouriteCount: Int {
        model.controllable.filter { model.meta[$0.id]?.isFavourite == true }.count
    }

    private var matching: [PairedDevice] {
        switch filter {
        case .all: return filteredByQuery
        case .online: return filteredByQuery.filter { model.presence[$0.id] == true }
        case .favourites: return filteredByQuery.filter { model.meta[$0.id]?.isFavourite == true }
        }
    }

    /// The matching Macs in the order last worked out; any that joined since go last.
    private var devices: [PairedDevice] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return matching.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count, $0.offset) < (rank[$1.element.id] ?? order.count, $1.offset) }
            .map(\.element)
    }

    /// Favourites first, then online Macs before offline ones.
    private func resort() {
        order = matching.enumerated().sorted { a, b in
            let fa = model.meta[a.element.id]?.isFavourite == true
            let fb = model.meta[b.element.id]?.isFavourite == true
            if fa != fb { return fa }
            let oa = model.presence[a.element.id] == true
            let ob = model.presence[b.element.id] == true
            if oa != ob { return oa }
            return a.offset < b.offset
        }.map(\.element.id)
    }

    var body: some View {
        Group {
            if model.controllable.isEmpty {
                EmptyDevices()
            } else {
                grid
            }
        }
        .onAppear(perform: resort)
        .onChange(of: filter) { _, _ in resort() }
        .onChange(of: query) { _, _ in resort() }
        .onChange(of: model.controllable.map(\.id)) { _, _ in resort() }
        // The first answer after none at all: online Macs move up once.
        .onChange(of: model.presence.isEmpty) { _, _ in resort() }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { device in
            TextField("Name", text: $newName)
            Button("Save") { model.rename(device, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The name is used on this Mac only. Leave it empty to use the Mac's own name.")
        }
        .alert(forgetting.map { "Forget \(model.displayName($0))?" } ?? "",
               isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
               presenting: forgetting) { device in
            Button("Forget", role: .destructive) { model.forget(device) }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("You'll need a new pairing code from \(model.displayName(device)) to control it again.")
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(DeviceFilter.allCases) { f in
                    let count = f == .all ? model.controllable.count : f == .online ? onlineCount : favouriteCount
                    Button { filter = f } label: {
                        HStack(spacing: 4) {
                            if f == .online {
                                Circle().fill(count > 0 ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                            } else if f == .favourites {
                                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(filter == f ? .white : .yellow)
                            }
                            Text("\(f.title) (\(count))").font(.callout.weight(filter == f ? .semibold : .regular)).monospacedDigit()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(filter == f ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                        .foregroundStyle(filter == f ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(f.title), \(count)")
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
                Spacer()
                Button { model.refreshPresence() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(model.signalingStatus != .online)
                .help("Refresh which Macs are online")
            }

            let devices = devices
            if devices.isEmpty {
                Text(filter == .online ? "No paired Macs are online right now."
                     : filter == .favourites ? "No favourite Macs yet. Click the star on a tile to pin it."
                     : "No paired Mac matches your search.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    // Not LazyVGrid: in a window that opens with its last size, the lazy grid left
                    // the tiles undrawn until the window was resized. A paired-Mac list is short.
                    TileGrid(minWidth: 250, maxWidth: 360, spacing: 20) {
                        ForEach(devices) { device in
                            DeviceTile(device: device,
                                       rename: { newName = model.displayName(device); renaming = device },
                                       forget: { forgetting = device })
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct EmptyDevices: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No Macs yet").font(.title3.weight(.semibold))
            step(1, "On the Mac you want to control, open MacBridge and turn on Allow control.")
            step(2, "There, click Show pairing code.")
            step(3, "Here, type that code in the field above and click Pair.")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DeviceTile: View {
    @EnvironmentObject private var model: BridgeModel
    let device: PairedDevice
    let rename: () -> Void
    let forget: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    private var meta: DeviceMeta { model.meta[device.id] ?? DeviceMeta() }
    private var isCalling: Bool { model.controllerStatus == .calling(device) }
    private var canConnect: Bool { model.signalingStatus == .online }
    private var isOnline: Bool? { model.presence[device.id] }

    var body: some View {
        // The star is a control of its own, beside the tile's button rather than inside it.
        ZStack(alignment: .topTrailing) {
            tileButton
            if hovering || meta.isFavourite {
                Button { model.setFavourite(device, !meta.isFavourite) } label: {
                    Image(systemName: meta.isFavourite ? "star.fill" : "star")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(meta.isFavourite ? .yellow : .white)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(meta.isFavourite ? "Remove from Favourites" : "Add to Favourites")
                .accessibilityLabel(meta.isFavourite ? "Remove \(model.displayName(device)) from Favourites" : "Add \(model.displayName(device)) to Favourites")
            }
        }
        .onHover { hovering = $0 }
        .task(id: device.id) { thumbnail = Thumbnails.image(for: device.id) }
        // A session that just ended may save its picture after this appeared.
        .onReceive(NotificationCenter.default.publisher(for: Thumbnails.changed)) { note in
            if note.object as? String == device.id { thumbnail = Thumbnails.image(for: device.id) }
        }
    }

    private var tileButton: some View {
        Button(action: { if isCalling { model.disconnect() } else { model.connect(to: device) } }) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        PresenceDot(online: isOnline)
                        Text(model.displayName(device)).font(.title3.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if meta.isFavourite {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                .accessibilityLabel("Favourite")
                        }
                    }
                    Text(DeviceID.grouped(device.id)).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Text(lastUsed).font(.callout).foregroundStyle(.tertiary)
                }
                .padding(14)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering && canConnect ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: hovering && canConnect ? 2 : 1))
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.04), radius: hovering ? 10 : 3, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!canConnect && !isCalling)
        .opacity(canConnect || isCalling ? (isOnline == false ? 0.78 : 1) : 0.6)
        .help(canConnect ? "Connect to \(model.displayName(device))" : "This Mac is offline")
        .accessibilityHint(isCalling ? "Cancels connecting" : "Connects to this Mac")
        .contextMenu {
            Button("Connect") { model.connect(to: device) }.disabled(!canConnect)
            Divider()
            Button("Rename…", action: rename)
            Button(meta.isFavourite ? "Remove from Favourites" : "Add to Favourites") { model.setFavourite(device, !meta.isFavourite) }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DeviceID.grouped(device.id), forType: .string)
            }
            Divider()
            Button("Forget \(model.displayName(device))…", role: .destructive, action: forget)
        }
    }

    private var preview: some View {
        // The picture is laid over a box of fixed shape, so a wide screenshot cannot widen the tile.
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .accessibilityHidden(true)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "desktopcomputer").font(.system(size: 48, weight: .light)).foregroundStyle(.white.opacity(0.9))
                    }
                    .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                if let online = isOnline {
                    HStack(spacing: 4) {
                        Circle().fill(online ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        Text(online ? "Online" : "Offline").font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                    .accessibilityHidden(true) // the dot by the name says it
                }
            }
            .overlay {
                if isCalling {
                    ZStack {
                        Color.black.opacity(0.45)
                        VStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("Connecting… click to cancel").font(.caption).foregroundStyle(.white)
                        }
                    }
                } else if hovering && canConnect {
                    ZStack {
                        Color.black.opacity(0.18)
                        Label("Connect", systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                }
            }
            .clipped()
    }

    private var lastUsed: String {
        guard let date = meta.lastConnected else { return "Never connected" }
        return "Last connected \(date.formatted(.relative(presentation: .named)))"
    }
}

/// Green when the server says the Mac is connected, grey when it is not, hidden while unknown.
struct PresenceDot: View {
    let online: Bool?

    var body: some View {
        if let online {
            Circle().fill(online ? Color.green : Color.secondary.opacity(0.45)).frame(width: 8, height: 8)
                .help(online ? "Online" : "Offline")
                .accessibilityLabel(online ? "Online" : "Offline")
        }
    }
}

/// Pictures of each Mac's screen from the last session (filled in by the session window).
enum Thumbnails {
    static var folder: URL {
        // A layout snapshot must leave the real pictures alone.
        if ProcessInfo.processInfo.environment["MACBRIDGE_SNAPSHOT"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("MacBridge-snapshot-thumbnails", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacBridge/Thumbnails", isDirectory: true)
    }

    static func url(for deviceID: String) -> URL { folder.appendingPathComponent("\(deviceID).jpg") }

    /// Read from disk once per picture, not on every redraw of a tile.
    @MainActor private static var cache: [String: NSImage?] = [:]

    @MainActor static func image(for deviceID: String) -> NSImage? {
        if let cached = cache[deviceID] { return cached }
        let image = NSImage(contentsOf: url(for: deviceID))
        cache[deviceID] = .some(image)
        return image
    }

    /// Keeps the last picture of a session as the Mac's tile picture.
    @MainActor static func save(from video: RemoteVideo, for deviceID: String?) {
        guard let deviceID, let data = video.thumbnailJPEG() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(for: deviceID), options: .atomic)
        cache[deviceID] = nil
        NotificationCenter.default.post(name: changed, object: deviceID)
    }

    /// Posted with the device ID as object when its picture was replaced.
    static let changed = Notification.Name("MacBridge.thumbnailChanged")
}
