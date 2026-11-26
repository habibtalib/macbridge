#if os(macOS)
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

/// Which stream is the current one. Every start and stop moves on to a new
/// generation, so a start still waiting on ScreenCaptureKit when another start
/// or a stop comes in cannot install its stream afterwards.
struct StreamSlot<Stream: AnyObject> {
    private(set) var current: Stream?
    private(set) var generation = 0

    /// A start or stop begins. Returns its generation and the stream it takes
    /// over, which the caller stops.
    mutating func advance() -> (generation: Int, previous: Stream?) {
        generation += 1
        defer { current = nil }
        return (generation, current)
    }

    /// The stream a start produced becomes current only if nothing came after
    /// that start. False: the caller stops it again.
    mutating func install(_ stream: Stream, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        current = stream
        return true
    }

    func isCurrent(_ stream: Stream) -> Bool { current === stream }

    /// The system stopped `stream`. True if it was the current one, which is
    /// then cleared; a stream already replaced or stopped on purpose is ignored.
    mutating func remove(_ stream: Stream) -> Bool {
        guard current === stream else { return false }
        current = nil
        return true
    }
}

/// Captures one display with ScreenCaptureKit and hands out frames ready for
/// the video encoder.
public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Sets what is called on a private queue for every new frame. Changes are
    /// applied on that queue, in the order they were made. Set-only: reading it
    /// back would mean waiting on that queue.
    public func setOnFrame(_ handler: ((CVPixelBuffer, _ timestampNs: Int64) -> Void)?) {
        frameQueue.async { self.frameHandler = handler }
    }
    /// Called if the system stops the current stream (permission revoked, display unplugged).
    /// Set it once, before the first start.
    public var onStop: ((Error?) -> Void)?

    private let frameQueue = DispatchQueue(label: "macbridge.capture", qos: .userInteractive)
    // Guarded by `frameQueue`.
    private var frameHandler: ((CVPixelBuffer, Int64) -> Void)?
    private var slot = StreamSlot<SCStream>()
    /// ScreenCaptureKit sends nothing while the screen is still. The last
    /// frame is sent again on a timer so the viewer never waits on a lost or
    /// not-yet-sent first frame (a black picture until something moves).
    private var lastFrame: CVPixelBuffer?
    private var lastFrameAt: TimeInterval = 0
    private var repeatTimer: DispatchSourceTimer?
    static let repeatInterval: TimeInterval = 0.5

    public override init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user has to
    /// change it in System Settings. Returns the current state.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public static func displays() async throws -> [DisplayInfo] {
        try await shareableDisplays().map(info(for:))
    }

    /// Starts capturing, replacing any stream already running.
    /// `displayID == nil` means the main display.
    /// Frames are scaled down, keeping the aspect ratio, so that neither side
    /// exceeds `maxPixelWidth` × `maxPixelHeight`.
    /// Throws `CancellationError` if `stop()` or another start came in meanwhile.
    @discardableResult
    public func start(
        displayID: CGDirectDisplayID? = nil,
        maxPixelWidth: Int = 2560,
        maxPixelHeight: Int = 1600,
        framesPerSecond: Int = 60
    ) async throws -> DisplayInfo {
        let (generation, previous) = frameQueue.sync { detachLocked() }
        try? await previous?.stopCapture()
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
        // One buffer stays held as the frame to repeat.
        config.queueDepth = 4

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        let installed = frameQueue.sync { () -> Bool in
            guard slot.install(stream, generation: generation) else { return false }
            startRepeatingLocked()
            return true
        }
        guard installed else {
            // Stopped or replaced while starting: this stream must not keep running unowned.
            try? await stream.stopCapture()
            throw CancellationError()
        }
        return info
    }

    /// Stops the current stream, and any start still in progress.
    public func stop() async {
        let (_, previous) = frameQueue.sync { detachLocked() }
        try? await previous?.stopCapture()
    }

    /// On `frameQueue`. Moves to a new generation and takes the current stream
    /// out, with its repeat timer and held frame.
    private func detachLocked() -> (generation: Int, previous: SCStream?) {
        repeatTimer?.cancel()
        repeatTimer = nil
        lastFrame = nil
        return slot.advance()
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // On `frameQueue`. A stream being stopped may still deliver a frame or two.
        guard type == .screen, slot.isCurrent(stream), sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let seconds = sampleBuffer.presentationTimeStamp.seconds
        lastFrame = pixelBuffer
        lastFrameAt = Self.hostSeconds()
        frameHandler?(pixelBuffer, Int64(seconds * 1_000_000_000))
    }

    /// On `frameQueue`, like the stream output, so the two never race.
    private func startRepeatingLocked() {
        repeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now() + Self.repeatInterval, repeating: Self.repeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.lastFrame else { return }
            let now = Self.hostSeconds()
            guard now - self.lastFrameAt >= Self.repeatInterval else { return }
            self.lastFrameAt = now
            self.frameHandler?(frame, Int64(now * 1_000_000_000))
        }
        repeatTimer = timer
        timer.resume()
    }

    /// The host clock, the one ScreenCaptureKit stamps its frames with.
    private static func hostSeconds() -> TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        frameQueue.async {
            // Only the current stream ends the session; an old one stopped on purpose does not.
            guard self.slot.remove(stream) else { return }
            self.repeatTimer?.cancel()
            self.repeatTimer = nil
            self.lastFrame = nil
            self.onStop?(error)
        }
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
#endif
