import BridgeCore
import SwiftUI

/// The remote Mac's screen, with input going to it while the pointer is over it.
struct SessionView: View {
    @EnvironmentObject private var model: BridgeModel
    let video: RemoteVideo

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
            ToolbarItem(placement: .primaryAction) {
                Button("Disconnect", systemImage: "xmark.circle") { model.disconnect() }
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var title: String {
        switch model.controllerStatus {
        case let .connected(host), let .calling(host): return host
        default: return "MacBridge"
        }
    }
}
