import AppKit
import SwiftUI
import WebRTC

/// A host's screen stream, as received by the controller.
public struct RemoteVideo: Identifiable {
    let track: RTCVideoTrack
    public var id: ObjectIdentifier { ObjectIdentifier(track) }
}

/// The remote screen. Renders a WebRTC video track with Metal and reports the
/// stream's pixel size so the caller can keep the aspect ratio.
public struct RemoteVideoView: NSViewRepresentable {
    private let track: RTCVideoTrack
    private let onVideoSize: (CGSize) -> Void

    public init(_ video: RemoteVideo, onVideoSize: @escaping (CGSize) -> Void = { _ in }) {
        self.track = video.track
        self.onVideoSize = onVideoSize
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.onVideoSize = onVideoSize
        context.coordinator.attach(track, to: view)
        return view
    }

    public func updateNSView(_ view: RTCMTLNSVideoView, context: Context) {
        context.coordinator.onVideoSize = onVideoSize
        context.coordinator.attach(track, to: view)
    }

    public static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }

    public final class Coordinator: NSObject, RTCVideoViewDelegate {
        var onVideoSize: (CGSize) -> Void = { _ in }
        private var track: RTCVideoTrack?

        func attach(_ newTrack: RTCVideoTrack, to view: RTCMTLNSVideoView) {
            guard track !== newTrack else { return }
            track?.remove(view)
            track = newTrack
            newTrack.add(view)
        }

        func detach(from view: RTCMTLNSVideoView) {
            track?.remove(view)
            track = nil
        }

        public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            DispatchQueue.main.async { self.onVideoSize(size) }
        }
    }
}
