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

    private var filteredByQuery: [PairedDevice] {
        ConnectInput.filter(model.controllableSorted, query, names: model.displayNames)
    }

    private var onlineCount: Int {
        model.controllable.filter { model.presence[$0.id] == true }.count
    }

    private var favouriteCount: Int {
        model.controllable.filter { model.meta[$0.id]?.isFavourite == true }.count
    }

    private var devices: [PairedDevice] {
        let base: [PairedDevice]
        switch filter {
        case .all: base = filteredByQuery
        case .online: base = filteredByQuery.filter { model.presence[$0.id] == true }
        case .favourites: base = filteredByQuery.filter { model.meta[$0.id]?.isFavourite == true }
        }
        // Keep favourites first, then online Macs before offline ones.
        return base.sorted { a, b in
            let fa = model.meta[a.id]?.isFavourite == true
            let fb = model.meta[b.id]?.isFavourite == true
            if fa != fb { return fa }
            let oa = model.presence[a.id] == true
            let ob = model.presence[b.id] == true
            if oa != ob { return oa }
            return false
        }
    }

    var body: some View {
        if model.controllable.isEmpty {
            EmptyDevices()
        } else {
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

                if devices.isEmpty {
                    Text(filter == .online ? "No paired Macs are online right now."
                         : filter == .favourites ? "No favourite Macs yet. Click the star on a tile to pin it."
                         : "No paired Mac matches your search.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 20)], alignment: .leading, spacing: 20) {
                            ForEach(devices) { device in
                                DeviceTile(device: device)
                            }
                        }
                        .padding(.vertical, 2)
                    }
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
    @State private var hovering = false
    @State private var renaming = false
    @State private var confirmingForget = false
    @State private var newName = ""

    private var meta: DeviceMeta { model.meta[device.id] ?? DeviceMeta() }
    private var isCalling: Bool { model.controllerStatus == .calling(device) }
    private var canConnect: Bool { model.signalingStatus == .online }
    private var isOnline: Bool? { model.presence[device.id] }

    var body: some View {
        Button(action: { if isCalling { model.disconnect() } else { model.connect(to: device) } }) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        PresenceDot(online: isOnline)
                        Text(model.displayName(device)).font(.title3.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if meta.isFavourite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
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
        .onHover { hovering = $0 }
        .help(canConnect ? "Connect to \(model.displayName(device))" : "This Mac is offline")
        .contextMenu {
            Button("Connect") { model.connect(to: device) }.disabled(!canConnect)
            Divider()
            Button("Rename…") { newName = model.displayName(device); renaming = true }
            Button(meta.isFavourite ? "Remove from Favourites" : "Add to Favourites") { model.setFavourite(device, !meta.isFavourite) }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DeviceID.grouped(device.id), forType: .string)
            }
            Divider()
            Button("Forget \(model.displayName(device))…", role: .destructive) { confirmingForget = true }
        }
        .alert("Rename \(device.name)", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { model.rename(device, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name is used on this Mac only. Leave it empty to use the Mac's own name.")
        }
        .alert("Forget \(model.displayName(device))?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { model.forget(device) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need a new pairing code from \(model.displayName(device)) to control it again.")
        }
    }

    private var preview: some View {
        // The picture is laid over a box of fixed shape, so a wide screenshot cannot widen the tile.
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = Thumbnails.image(for: device.id) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "desktopcomputer").font(.system(size: 48, weight: .light)).foregroundStyle(.white.opacity(0.9))
                    }
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
                }
            }
            .overlay(alignment: .topTrailing) {
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacBridge/Thumbnails", isDirectory: true)
    }

    static func url(for deviceID: String) -> URL { folder.appendingPathComponent("\(deviceID).jpg") }

    static func image(for deviceID: String) -> NSImage? { NSImage(contentsOf: url(for: deviceID)) }

    /// Keeps the last picture of a session as the Mac's tile picture.
    @MainActor static func save(from video: RemoteVideo, for deviceID: String?) {
        guard let deviceID, let data = video.thumbnailJPEG() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(for: deviceID), options: .atomic)
    }
}
