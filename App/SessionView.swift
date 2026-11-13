import BridgeCore
import SwiftUI

/// The remote Mac's screen, with input going to it while the pointer is over it.
struct SessionView: View {
    @EnvironmentObject private var model: BridgeModel
    let video: RemoteVideo
    @State private var quality = QualityPreset.sharp

    var body: some View {
        ZStack {
            Color.black
            RemoteVideoView(video) { model.setRemoteVideoSize($0) }
                .overlay(InputCaptureView { model.sendInput($0) })
                .aspectRatio(model.remoteVideoSize ?? CGSize(width: 16, height: 10), contentMode: .fit)
        }
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(title).font(.headline)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Quality", selection: $quality) {
                    Text("Sharp").tag(QualityPreset.sharp)
                    Text("Balanced").tag(QualityPreset.balanced)
                    Text("Light").tag(QualityPreset.light)
                }
                .help("Sharp: full detail at 60 fps. Light: smaller and slower, for weak connections.")
                .onChange(of: quality) { _, preset in model.sendInput(.quality(preset)) }

                Button("Next Display", systemImage: "display.2") { model.sendInput(.nextDisplay) }
                    .help("Show the other Mac's next display")

                Button("Disconnect", systemImage: "xmark.circle") { model.disconnect() }
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var title: String {
        switch model.controllerStatus {
        case let .connected(host), let .calling(host): return host.name
        default: return "MacBridge"
        }
    }
}
