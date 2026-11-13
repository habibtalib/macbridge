import BridgeCore
import SwiftUI

@main
struct MacBridgeApp: App {
    var body: some Scene {
        WindowGroup("MacBridge") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("MacBridge")
                .font(.title2.weight(.semibold))
            Text("Protocol v\(InputMessage.protocolVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 320)
    }
}
