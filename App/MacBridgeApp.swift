import BridgeCore
import SwiftUI

@main
struct MacBridgeApp: App {
    /// Nil if the identity key could not be loaded from the keychain.
    @StateObject private var launch = Launch()

    var body: some Scene {
        Window("MacBridge", id: "main") {
            if let model = launch.model {
                RootView()
                    .environmentObject(model)
                    .onAppear { if model.canGoOnline { model.goOnline() } }
            } else {
                KeychainErrorView()
            }
        }
        .commands {
            // The remote screen takes ⌘ shortcuts while it has focus, so the
            // local "New Window" item would only get in the way.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class Launch: ObservableObject {
    let model: BridgeModel?

    init() {
        model = (try? Identity.loadOrCreate()).map { BridgeModel(identity: $0) }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: BridgeModel

    var body: some View {
        if let video = model.remoteVideo {
            SessionView(video: video)
        } else {
            HomeView()
        }
    }
}

struct KeychainErrorView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash").font(.system(size: 36)).foregroundStyle(.red)
            Text("MacBridge could not read its key from the keychain.")
                .font(.headline)
            Text("Unlock the login keychain and allow MacBridge access, then reopen the app. A new key is not created automatically, because that would unpair every device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(32)
        .frame(width: 420)
    }
}
