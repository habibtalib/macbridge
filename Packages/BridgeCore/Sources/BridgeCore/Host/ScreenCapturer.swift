import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public struct DisplayInfo: Identifiable, Equatable, Sendable {
    public let id: CGDirectDisplayID
    /// Size in points, the unit mouse events use.
    public let pointSize: CGSize
    /// Size in physical pixels.
    public let pixelSize: CGSize
    /// Position of the display in the global coordinate space, in points.
    public let origin: CGPoint
    public let isMain: Bool

    public var name: String {
        "\(isMain ? "Main display" : "Display \(id)") — \(Int(pixelSize.width))×\(Int(pixelSize.height))"
    }
}

public enum ScreenCaptureError: Error, Equatable {
    case permissionDenied
    case noDisplay
}

/// Captures one display with ScreenCaptureKit and hands out frames ready for
/// the video encoder.
public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on a private queue for every new frame.
    public var onFrame: ((CVPixelBuffer, _ timestampNs: Int64) -> Void)?
    /// Called if the system stops the stream (permission revoked, display unplugged).
    public var onStop: ((Error?) -> Void)?

    private let frameQueue = DispatchQueue(label: "macbridge.capture", qos: .userInteractive)
    private var stream: SCStream?

    public override init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user has to
    /// change it in System Settings. Returns the current state.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public static func displays() async throws -> [DisplayInfo] {
        try await shareableDisplays().map(info(for:))
    }

    /// Starts capturing. `displayID == nil` means the main display.
    /// Frames are scaled down, keeping the aspect ratio, so that neither side
    /// exceeds `maxPixelWidth` × `maxPixelHeight`.
    @discardableResult
    public func start(
        displayID: CGDirectDisplayID? = nil,
        maxPixelWidth: Int = 2560,
        maxPixelHeight: Int = 1600,
        framesPerSecond: Int = 60
    ) async throws -> DisplayInfo {
        await stop()
        let displays = try await Self.shareableDisplays()
        let wanted = displayID ?? CGMainDisplayID()
        guard let display = displays.first(where: { $0.displayID == wanted }) ?? displays.first else {
            throw ScreenCaptureError.noDisplay
        }
        let info = Self.info(for: display)
        let size = Self.fit(info.pixelSize, maxWidth: maxPixelWidth, maxHeight: maxPixelHeight)

        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        // NV12: what the hardware H.264 encoder takes without a conversion.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 3

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
        return info
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let seconds = sampleBuffer.presentationTimeStamp.seconds
        onFrame?(pixelBuffer, Int64(seconds * 1_000_000_000))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }

    // MARK: - Helpers

    /// ScreenCaptureKit also delivers "idle" and "blank" buffers with no new
    /// image; only complete frames carry pixels.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    private static func shareableDisplays() async throws -> [SCDisplay] {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
        } catch {
            if !hasPermission { throw ScreenCaptureError.permissionDenied }
            throw error
        }
    }

    private static func info(for display: SCDisplay) -> DisplayInfo {
        let id = display.displayID
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        let pixelSize = mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) } ?? bounds.size
        return DisplayInfo(
            id: id,
            pointSize: bounds.size,
            pixelSize: pixelSize,
            origin: bounds.origin,
            isMain: id == CGMainDisplayID()
        )
    }

    /// Largest size within the limits that keeps the aspect ratio, never
    /// upscaled, with even dimensions (required by the encoder).
    static func fit(_ size: CGSize, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard size.width > 0, size.height > 0 else { return (2, 2) }
        let scale = min(1, CGFloat(maxWidth) / size.width, CGFloat(maxHeight) / size.height)
        let even = { (value: CGFloat) in max(2, Int((value * scale).rounded(.down)) & ~1) }
        return (even(size.width), even(size.height))
    }
}
