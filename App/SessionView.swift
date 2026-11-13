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

                ControlGroup {
                    Button("Previous Desktop", systemImage: "chevron.left") { model.sendShortcut(.previousDesktop) }
                        .help("Switch the other Mac to the desktop on the left (Control-←)")
                    Button("Mission Control", systemImage: "rectangle.3.group") { model.sendShortcut(.missionControl) }
                        .help("Show Mission Control on the other Mac (Control-↑)")
                    Button("Next Desktop", systemImage: "chevron.right") { model.sendShortcut(.nextDesktop) }
                        .help("Switch the other Mac to the desktop on the right (Control-→)")
                }

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
