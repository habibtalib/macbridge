import AppKit
import BridgeCore
import SwiftUI

/// Renders a screen with made-up data to a PNG and quits, for checking layouts:
///
///     MACBRIDGE_SNAPSHOT=/tmp/home.png MACBRIDGE_SNAPSHOT_VIEW=home MacBridge.app/Contents/MacOS/MacBridge
///
/// Views: `home`, `empty`, `settings-general`, `settings-security`, `settings-connection`.
/// Nothing is read from or written to the real settings, and the app stays offline.
@MainActor
enum Snapshot {
    static var path: String? { ProcessInfo.processInfo.environment["MACBRIDGE_SNAPSHOT"] }
    static var view: String { ProcessInfo.processInfo.environment["MACBRIDGE_SNAPSHOT_VIEW"] ?? "home" }
    static var isActive: Bool { path != nil }

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
