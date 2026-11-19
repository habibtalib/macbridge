import BridgeCore
import SwiftUI
import VisionKit

/// The Macs this device can control, and the way to add one.
struct HomeScreen: View {
    @EnvironmentObject private var model: BridgeModel
    @State private var query = ""
    @State private var showsSettings = false
    @State private var showsScanner = false

    private var input: ConnectInput {
        ConnectInput.parse(query, devices: model.controllable, names: model.displayNames)
    }
    private var isOnline: Bool { model.signalingStatus == .online }
    private var devices: [PairedDevice] {
        ConnectInput.filter(model.controllableSorted, query, names: model.displayNames)
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
                    connectField
                    if model.controllable.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 16)], spacing: 16) {
                            ForEach(devices) { DeviceCard(device: $0) }
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
            .sheet(isPresented: $showsScanner) {
                CodeScanner { link in
                    showsScanner = false
                    query = link.code
                    model.pair(using: link)
                }
                .ignoresSafeArea()
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
                Text("Connecting…").foregroundStyle(.secondary)
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
                    Button { showsScanner = true } label: { Image(systemName: "qrcode.viewfinder").font(.title3) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Scan the pairing code on your Mac")
                }
            }
            if case let .failed(reason) = model.pairingStatus {
                Text(reason).font(.callout).foregroundStyle(.red)
            } else if case .pairingCode = input {
                Text("That looks like a pairing code. Pair to add the Mac that shows it.").font(.callout).foregroundStyle(.secondary)
            } else if !query.isEmpty, devices.isEmpty, !model.controllable.isEmpty {
                Text("No paired Mac matches.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No Macs yet").font(.title3.weight(.semibold))
            step(1, "On the Mac, open MacBridge and turn on Allow control.")
            step(2, "There, tap Show pairing code.")
            step(3, "Here, scan the code or type it in the field above, then tap Pair.")
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
    @State private var renaming = false
    @State private var newName = ""

    private var meta: DeviceMeta { model.meta[device.id] ?? DeviceMeta() }
    private var canConnect: Bool { model.signalingStatus == .online }

    var body: some View {
        Button { model.connect(to: device) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let image = Thumbnails.image(for: device.id) {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.15)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "desktopcomputer").font(.system(size: 48, weight: .light)).foregroundStyle(.white.opacity(0.9))
                            }
                        }
                    }
                    .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let online = model.presence[device.id] {
                            Circle().fill(online ? Color.green : Color.secondary.opacity(0.45)).frame(width: 9, height: 9)
                                .accessibilityLabel(online ? "Online" : "Offline")
                        }
                        Text(model.displayName(device)).font(.headline).lineLimit(1)
                        Spacer(minLength: 0)
                        if meta.isFavourite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
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
        .opacity(canConnect ? 1 : 0.6)
        .contextMenu {
            Button { model.connect(to: device) } label: { Label("Connect", systemImage: "play.fill") }.disabled(!canConnect)
            Button { newName = model.displayName(device); renaming = true } label: { Label("Rename", systemImage: "pencil") }
            Button { model.setFavourite(device, !meta.isFavourite) } label: {
                Label(meta.isFavourite ? "Remove from Favourites" : "Add to Favourites", systemImage: meta.isFavourite ? "star.slash" : "star")
            }
            Button(role: .destructive) { model.forget(device) } label: { Label("Forget", systemImage: "trash") }
        }
        .alert("Rename \(device.name)", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { model.rename(device, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used on this device only. Leave it empty to use the Mac's own name.")
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
