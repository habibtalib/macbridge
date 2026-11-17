import AppKit
import BridgeCore
import SwiftUI

/// Renders a screen with made-up data to a PNG and quits, for checking layouts:
///
///     MACBRIDGE_SNAPSHOT=/tmp/home.png MACBRIDGE_SNAPSHOT_VIEW=home MacBridge.app/Contents/MacOS/MacBridge
///
/// Views: `home`, `empty`, `connecting`, `dropped`, `stats`, `host-panel`, `ask`, `settings-general`,
/// `settings-security`, `settings-connection`.
/// Nothing is read from or written to the real settings, and the app stays offline.
@MainActor
enum Snapshot {
    static var path: String? { ProcessInfo.processInfo.environment["MACBRIDGE_SNAPSHOT"] }
    static var view: String { ProcessInfo.processInfo.environment["MACBRIDGE_SNAPSHOT_VIEW"] ?? "home" }
    static var isActive: Bool { path != nil }
    /// The sample tile picture, removed again after the render.
    private static var samplePicture: URL?

    static func sampleModel() -> BridgeModel {
        let suite = "macbridge-snapshot"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if view != "empty" {
            let names = ["Studio", "Mac mini", "MacBook Air", "Office iMac"]
            let devices = names.enumerated().map { index, name in
                let key = Data(repeating: UInt8(index + 1), count: 32)
                return PairedDevice(id: DeviceID.derive(fromPublicKey: key), publicKey: key, name: name,
                                    mayControlThisMac: index < 2, thisMacMayControl: true)
            }
            defaults.set(try? JSONEncoder().encode(devices), forKey: "pairedDevices")
            var meta: [String: DeviceMeta] = [:]
            var first = DeviceMeta()
            first.isFavourite = true
            first.lastConnected = Date().addingTimeInterval(-2 * 3600)
            meta[devices[0].id] = first
            var second = DeviceMeta()
            second.lastConnected = Date().addingTimeInterval(-3 * 86400)
            second.asksFirst = true
            meta[devices[1].id] = second
            defaults.set(try? JSONEncoder().encode(meta), forKey: "deviceMeta")
            // One tile with a wide picture, to check that it keeps the tile's shape.
            if let sample = NSImage(contentsOfFile: "/System/Library/CoreServices/DefaultDesktop.heic")?.tiffRepresentation,
               let jpeg = NSBitmapImageRep(data: sample)?.representation(using: .jpeg, properties: [:]) {
                try? FileManager.default.createDirectory(at: Thumbnails.folder, withIntermediateDirectories: true)
                let url = Thumbnails.url(for: devices[0].id)
                if !FileManager.default.fileExists(atPath: url.path), (try? jpeg.write(to: url)) != nil { samplePicture = url }
            }
        }
        defaults.set("Dark-MBP", forKey: "deviceName")
        defaults.set("wss://bridge.example.com", forKey: "serverURL")
        defaults.set(true, forKey: "allowsControl")
        return BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory(""))
    }

    static func run(model: BridgeModel) {
        guard let path else { return }
        let content: AnyView
        var size = CGSize(width: 860, height: 560)
        switch view {
        case "settings-general", "settings-security", "settings-connection":
            content = AnyView(SettingsSnapshot(tab: String(view.dropFirst("settings-".count))))
            size = CGSize(width: 520, height: 520)
        case "connecting":
            content = AnyView(ConnectingView(name: "Studio") {})
        case "dropped":
            content = AnyView(DroppedView(name: "Studio", reason: "Connection to Studio failed", reconnect: {}, close: {}))
        case "stats":
            var stats = SessionStats()
            stats.width = 2560; stats.height = 1600; stats.framesPerSecond = 59.6; stats.bitsPerSecond = 7_400_000
            stats.packets = 120_000; stats.packetsLost = 36; stats.roundTripMs = 12.4; stats.isRelayed = false
            stats.codec = "H264"; stats.usesHardware = true
            content = AnyView(VStack(alignment: .leading, spacing: 0) {
                ConnectionChip(name: "Studio", stats: stats).padding(8)
                Divider()
                StatsPanel(stats: stats)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)))
            size = CGSize(width: 320, height: 250)
        case "host-panel":
            content = AnyView(HostPanelView(name: "MacBook Air", started: Date().addingTimeInterval(-754), end: {}))
            size = CGSize(width: 320, height: 76)
        case "ask":
            content = AnyView(AskPanelView(name: "MacBook Air", deadline: Date().addingTimeInterval(24), accept: {}, decline: {}))
            size = CGSize(width: 360, height: 150)
        default:
            content = AnyView(HomeView())
        }
        let host = NSHostingView(rootView: content.environmentObject(model).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -3000, y: -3000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if let samplePicture { try? FileManager.default.removeItem(at: samplePicture) }
            exit(0)
        }
    }
}

/// One settings tab without the tab bar (a `TabView` does not draw off screen).
private struct SettingsSnapshot: View {
    let tab: String

    var body: some View {
        SettingsView(only: tab)
    }
}
