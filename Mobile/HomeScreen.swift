import AVFoundation
import BridgeCore
import SwiftUI
import VisionKit

private enum MobileDeviceFilter: String, CaseIterable, Identifiable {
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

/// The Macs this device can control, and the way to add one.
struct HomeScreen: View {
    @EnvironmentObject private var model: BridgeModel
    @State private var query = ""
    @State private var filter: MobileDeviceFilter = .all
    @State private var showsSettings = false
    @State private var showsScanner = false
    /// Read by the scanner; acted on once its sheet is gone, so a question it raises can show.
    @State private var scannedLink: PairingLink?
    @State private var cameraDenied = false
    /// Card order, by device ID. Worked out again when the filter, the search or the paired Macs
    /// change, not on every presence answer: a card must not move away from under a finger.
    @State private var order: [String] = []
    // Kept here, not in the card: a card can leave the list (its Mac went offline under the
    // Online filter) while its question is open.
    @State private var renaming: PairedDevice?
    @State private var forgetting: PairedDevice?
    @State private var newName = ""

    private var input: ConnectInput {
        ConnectInput.parse(query, devices: model.controllable, names: model.displayNames)
    }
    private var isOnline: Bool { model.signalingStatus == .online }
    private var onlineCount: Int { model.controllable.filter { model.presence[$0.id] == true }.count }
    private var favouriteCount: Int { model.controllable.filter { model.meta[$0.id]?.isFavourite == true }.count }

    private var showsFilters: Bool { model.controllable.count > 1 }

    private var matching: [PairedDevice] {
        let matched = ConnectInput.filter(model.controllableSorted, query, names: model.displayNames)
        switch filter {
        case .all: return matched
        case .online: return matched.filter { model.presence[$0.id] == true }
        case .favourites: return matched.filter { model.meta[$0.id]?.isFavourite == true }
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.notice {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                            Text(notice)
                            Spacer()
                            Button("OK") { model.dismissNotice() }
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    status
                    if let waiting = model.hostAwaitingServer {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Connecting to \(model.displayName(waiting))… (waiting for server)")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("Cancel") { model.disconnect() }.buttonStyle(.bordered)
                        }
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    connectField
                    if showsFilters {
                        filterPills
                    }
                    if model.controllable.isEmpty {
                        emptyState
                    } else if devices.isEmpty {
                        Text(filter == .online ? "No paired Macs are online right now."
                             : filter == .favourites ? "No favourite Macs yet. Tap the star on a card to pin it."
                             : "No paired Mac matches.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 16)], spacing: 16) {
                            ForEach(devices) { device in
                                DeviceCard(device: device,
                                           rename: { newName = model.displayName(device); renaming = device },
                                           forget: { forgetting = device })
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("MacBridge")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsScreen() }
            .sheet(isPresented: $showsScanner, onDismiss: {
                if let link = scannedLink { model.pair(using: link) }
                scannedLink = nil
            }) {
                ZStack(alignment: .top) {
                    CodeScanner { link in
                        scannedLink = link
                        query = link.code
                        showsScanner = false
                    }
                    .ignoresSafeArea()
                    HStack {
                        Label("Point at the QR code on your Mac", systemImage: "qrcode.viewfinder")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        Button { showsScanner = false } label: {
                            Image(systemName: "xmark")
                                .font(.headline)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Close scanner")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                }
            }
            .refreshable { model.refreshPresence() }
            .task(id: model.signalingStatus) {
                while !Task.isCancelled {
                    model.refreshPresence()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .onChange(of: model.paired) { _, _ in
                if model.pairingStatus == .idle, case .pairingCode = input { query = "" }
                model.refreshPresence()
            }
            .onAppear(perform: resort)
            .onChange(of: filter) { _, _ in resort() }
            .onChange(of: query) { _, _ in resort() }
            .onChange(of: model.controllable.map(\.id)) { _, _ in resort() }
            // The first answer after none at all: online Macs move up once.
            .onChange(of: model.presence.isEmpty) { _, _ in resort() }
            // With the pills hidden, a filter left on could hide the only Mac.
            .onChange(of: showsFilters, initial: true) { _, shows in if !shows { filter = .all } }
            .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { device in
                TextField("Name", text: $newName)
                Button("Save") { model.rename(device, to: newName) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Used on this device only. Leave it empty to use the Mac's own name.")
            }
            .alert(forgetting.map { "Forget \(model.displayName($0))?" } ?? "",
                   isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                   presenting: forgetting) { device in
                Button("Forget", role: .destructive) { model.forget(device) }
                Button("Cancel", role: .cancel) {}
            } message: { device in
                Text("You'll need a new pairing code from \(model.displayName(device)) to control it again.")
            }
            .alert("Camera access is off", isPresented: $cameraDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MacBridge uses the camera only to read the pairing code your Mac shows. Turn on Camera for MacBridge in Settings, or type the code in the field instead.")
            }
        }
    }

    /// Asks for the camera the first time; explains when it has been turned off.
    private func openScanner() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showsScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { showsScanner = true } else { cameraDenied = true }
                }
            }
        default:
            cameraDenied = true
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            switch model.signalingStatus {
            case .online:
                Circle().fill(.green).frame(width: 9, height: 9)
                Text("Online").foregroundStyle(.secondary)
            case .connecting:
                ProgressView().controlSize(.small)
                Text(model.isOnLocalNetwork ? "Local network · connecting to server…" : "Connecting…").foregroundStyle(.secondary)
            case .offline where model.isOnLocalNetwork:
                Circle().fill(.green).frame(width: 9, height: 9)
                Text("Local network only").foregroundStyle(.secondary)
                Spacer()
                if model.canGoOnline {
                    Button("Go online") { model.goOnline() }.buttonStyle(.bordered)
                }
            case .offline:
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
                Text("Offline").foregroundStyle(.secondary)
                Spacer()
                if model.canGoOnline {
                    Button("Go online") { model.goOnline() }.buttonStyle(.bordered)
                } else {
                    Button("Set up server") { showsSettings = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .font(.callout)
    }

    private var connectField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Name, address or pairing code", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(submit)
                    if !query.isEmpty {
                        Button { query = ""; model.cancelPairing() } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if model.pairingStatus == .waiting {
                    ProgressView()
                } else if case .pairingCode = input {
                    Button("Pair", action: submit).buttonStyle(.borderedProminent).disabled(!isOnline)
                } else if DataScannerViewController.isSupported {
                    Button(action: openScanner) { Image(systemName: "qrcode.viewfinder").font(.title3) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Scan the pairing code on your Mac")
                }
            }
            if let confirm = model.pairingStatus.serverToConfirm {
                Text(confirm.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Use \(confirm.host)") { model.confirmServerSwitch() }.buttonStyle(.borderedProminent)
                    Button("Cancel") { query = ""; model.cancelPairing() }.buttonStyle(.bordered)
                }
            } else if case let .failed(reason) = model.pairingStatus {
                Text(reason).font(.callout).foregroundStyle(.red)
            } else if case .pairingCode = input {
                Text("That looks like a pairing code. Pair to add the Mac that shows it.").font(.callout).foregroundStyle(.secondary)
            } else if !query.isEmpty, devices.isEmpty, !model.controllable.isEmpty {
                Text("No paired Mac matches.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MobileDeviceFilter.allCases) { f in
                    let count = f == .all ? model.controllable.count : f == .online ? onlineCount : favouriteCount
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        filter = f
                    } label: {
                        HStack(spacing: 5) {
                            if f == .online {
                                Circle().fill(count > 0 ? Color.green : Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
                            } else if f == .favourites {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(filter == f ? .white : .yellow)
                            }
                            Text("\(f.title) (\(count))").font(.subheadline.weight(filter == f ? .semibold : .regular)).monospacedDigit()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(filter == f ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: Capsule())
                        .foregroundStyle(filter == f ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(f.title), \(count)")
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No Macs yet").font(.title3.weight(.semibold))
            step(1, "On the Mac, open MacBridge and turn on Allow control.")
            step(2, "There, tap Show pairing code.")
            // No camera scanning here (Vision Pro, a simulator): the code is typed.
            step(3, DataScannerViewController.isSupported
                 ? "Here, scan the code or type it in the field above, then tap Pair."
                 : "Here, type the code in the field above, then tap Pair.")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
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

private struct DeviceCard: View {
    @EnvironmentObject private var model: BridgeModel
    let device: PairedDevice
    let rename: () -> Void
    let forget: () -> Void
    @State private var thumbnail: UIImage?

    private var meta: DeviceMeta { model.meta[device.id] ?? DeviceMeta() }
    private var canConnect: Bool { model.canConnect(to: device) }
    private var isOnline: Bool? { model.presence[device.id] }

    var body: some View {
        // The star is a control of its own, beside the card's button rather than inside it.
        ZStack(alignment: .topTrailing) {
            cardButton
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                model.setFavourite(device, !meta.isFavourite)
            } label: {
                Image(systemName: meta.isFavourite ? "star.fill" : "star")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(meta.isFavourite ? .yellow : .white)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(meta.isFavourite ? "Remove \(model.displayName(device)) from Favourites" : "Add \(model.displayName(device)) to Favourites")
        }
        .task(id: device.id) { thumbnail = Thumbnails.image(for: device.id) }
        // A session that just ended may save its picture after this appeared.
        .onReceive(NotificationCenter.default.publisher(for: Thumbnails.changed)) { note in
            if note.object as? String == device.id { thumbnail = Thumbnails.image(for: device.id) }
        }
    }

    private var cardButton: some View {
        Button { model.connect(to: device) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let thumbnail {
                            Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                                .accessibilityHidden(true)
                        } else {
                            ZStack {
                                LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.15)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "desktopcomputer").font(.system(size: 48, weight: .light)).foregroundStyle(.white.opacity(0.9))
                            }
                            .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let online = isOnline {
                            HStack(spacing: 4) {
                                Circle().fill(online ? Color.green : Color.secondary).frame(width: 7, height: 7)
                                Text(online ? "Online" : "Offline").font(.caption2.weight(.semibold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                            .accessibilityHidden(true) // the dot by the name says it
                        }
                    }
                    .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let online = isOnline {
                            Circle().fill(online ? Color.green : Color.secondary.opacity(0.45)).frame(width: 9, height: 9)
                                .accessibilityLabel(online ? "Online" : "Offline")
                        }
                        Text(model.displayName(device)).font(.headline).lineLimit(1)
                        Spacer(minLength: 0)
                        if meta.isFavourite {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                .accessibilityLabel("Favourite")
                        }
                    }
                    Text(DeviceID.grouped(device.id)).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Text(lastUsed).font(.footnote).foregroundStyle(.tertiary)
                }
                .padding(14)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canConnect)
        .opacity(canConnect ? (isOnline == false ? 0.78 : 1) : 0.6)
        .accessibilityHint("Connects to this Mac")
        .contextMenu {
            Button { model.connect(to: device) } label: { Label("Connect", systemImage: "play.fill") }.disabled(!canConnect)
            Button(action: rename) { Label("Rename", systemImage: "pencil") }
            Button { model.setFavourite(device, !meta.isFavourite) } label: {
                Label(meta.isFavourite ? "Remove from Favourites" : "Add to Favourites", systemImage: meta.isFavourite ? "star.slash" : "star")
            }
            Button { UIPasteboard.general.string = DeviceID.grouped(device.id) } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: forget) { Label("Forget", systemImage: "trash") }
        }
    }

    private var lastUsed: String {
        guard let date = meta.lastConnected else { return "Never connected" }
        return "Last connected \(date.formatted(.relative(presentation: .named)))"
    }
}

/// Camera view that reads the QR code a Mac shows under "Show pairing code".
private struct CodeScanner: UIViewControllerRepresentable {
    let found: (PairingLink) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (PairingLink) -> Void
        private var done = false
        init(found: @escaping (PairingLink) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case let .barcode(code) in added {
                // Only a MacBridge pairing code or link counts; any other QR code is ignored.
                guard let text = code.payloadStringValue, let link = PairingLink(text) else { continue }
                done = true
                scanner.stopScanning()
                found(link)
                return
            }
        }
    }
}
