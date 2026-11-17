#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreImage
import SwiftUI
import WebRTC

/// A host's screen stream, as received by the controller.
public struct RemoteVideo: Identifiable {
    let track: RTCVideoTrack
    private let latest = LatestFrame()
    public var id: ObjectIdentifier { ObjectIdentifier(track) }

    init(track: RTCVideoTrack) {
        self.track = track
        track.add(latest)
    }

    /// A small JPEG of the newest picture, for the Mac's tile. nil before the first picture.
    public func thumbnailJPEG(maxWidth: CGFloat = 640) -> Data? {
        guard let buffer = latest.pixelBuffer else { return nil }
        return Self.jpeg(from: buffer, maxWidth: maxWidth)
    }

    static func jpeg(from buffer: CVPixelBuffer, maxWidth: CGFloat) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, maxWidth / max(1, image.extent.width))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIContext().jpegRepresentation(of: image, colorSpace: space, options: [:])
    }
}

/// Remembers the newest decoded picture of a track. A few a second are enough.
final class LatestFrame: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var lastKept = Date.distantPast

    var pixelBuffer: CVPixelBuffer? { lock.withLock { buffer } }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let pixels = (frame?.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }
        let now = Date()
        lock.withLock {
            guard now.timeIntervalSince(lastKept) > 0.5 else { return }
            lastKept = now
            buffer = pixels
        }
    }
}

#if os(macOS)
typealias PlatformVideoView = RTCMTLNSVideoView
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformVideoView = RTCMTLVideoView
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// The remote screen. Renders a WebRTC video track with Metal and reports the
/// stream's pixel size so the caller can keep the aspect ratio.
public struct RemoteVideoView: PlatformViewRepresentable {
    private let track: RTCVideoTrack
    private let onVideoSize: (CGSize) -> Void

    public init(_ video: RemoteVideo, onVideoSize: @escaping (CGSize) -> Void = { _ in }) {
        self.track = video.track
        self.onVideoSize = onVideoSize
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    private func make(_ context: Context) -> PlatformVideoView {
        let view = PlatformVideoView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.onVideoSize = onVideoSize
        context.coordinator.attach(track, to: view)
        return view
    }

    private func update(_ view: PlatformVideoView, _ context: Context) {
        context.coordinator.onVideoSize = onVideoSize
        context.coordinator.attach(track, to: view)
    }

    #if os(macOS)
    public func makeNSView(context: Context) -> RTCMTLNSVideoView { make(context) }
    public func updateNSView(_ view: RTCMTLNSVideoView, context: Context) { update(view, context) }
    public static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: Coordinator) { coordinator.detach(from: view) }
    #else
    public func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = make(context)
        // The caller sizes the view to the picture's shape; never crop.
        view.videoContentMode = .scaleAspectFit
        return view
    }
    public func updateUIView(_ view: RTCMTLVideoView, context: Context) { update(view, context) }
    public static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) { coordinator.detach(from: view) }
    #endif

    public final class Coordinator: NSObject, RTCVideoViewDelegate {
        var onVideoSize: (CGSize) -> Void = { _ in }
        private var track: RTCVideoTrack?

        func attach(_ newTrack: RTCVideoTrack, to view: RTCVideoRenderer) {
            guard track !== newTrack else { return }
            track?.remove(view)
            track = newTrack
            newTrack.add(view)
        }

        func detach(from view: RTCVideoRenderer) {
            track?.remove(view)
            track = nil
        }

        public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            DispatchQueue.main.async { self.onVideoSize(size) }
        }
    }
}
