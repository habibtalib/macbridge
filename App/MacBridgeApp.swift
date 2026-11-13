import BridgeCore
import SwiftUI

@main
struct MacBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        Window("MacBridge", id: "main") {
            RootView()
                .environmentObject(model)
                .onAppear { if model.canGoOnline { model.goOnline() } }
        }
        .commands {
            // The remote screen takes ⌘ shortcuts while it has focus, so the
            // local "New Window" item would only get in the way.
            CommandGroup(replacing: .newItem) {}
        }
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
