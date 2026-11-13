import CoreVideo
import Foundation
import Testing
@testable import BridgeCore

/// A Retina-sized screen must stay on the hardware encoder at full size and a
/// usable frame rate. With WebRTC's stock codec list this silently fell back
/// to software VP8 at about one frame a second.
@Suite(.serialized) struct FullSizeVideoTests {
    @Test(.timeLimit(.minutes(1)))
    func retinaSizedScreenUsesHardwareAtFullSizeAndSpeed() async throws {
        let host = try #require(PeerSession(role: .host))
        let controller = try #require(PeerSession(role: .controller))
        defer { host.close(); controller.close() }
        host.onSignal = { controller.handle($0) }
        controller.onSignal = { host.handle($0) }
        host.start()

        // What ScreenCapturer produces for a 14" MacBook Pro: a static desktop
        // with one window-sized region changing every frame.
        let width = 2462, height = 1600
        let frames = try (0..<8).map { try #require(makeScreenLikeFrame(width: width, height: height, step: $0)) }

        let start = DispatchTime.now().uptimeNanoseconds
        for tick in 0..<(60 * 5) {
            host.push(frames[tick % frames.count], timestampNs: Int64(DispatchTime.now().uptimeNanoseconds - start))
            try await Task.sleep(for: .milliseconds(16))
        }

        let sent = try await stats(of: host), received = try await stats(of: controller)
        #expect(sent["encoderImplementation"] == "VideoToolbox")
        #expect(received["decoderImplementation"] == "VideoToolbox")
        #expect(sent["frameWidth"] == "\(width)" && sent["frameHeight"] == "\(height)")
        #expect(received["frameWidth"] == "\(width)" && received["frameHeight"] == "\(height)")
        // About 300 frames were pushed in 5 s; allow for start-up and a busy machine.
        #expect((Int(received["framesDecoded"] ?? "") ?? 0) > 150)
    }

    private func stats(of session: PeerSession) async throws -> [String: String] {
        let report = await withCheckedContinuation { continuation in
            session.videoStats { continuation.resume(returning: $0) }
        }
        return try #require(report.first)
    }
}

private func makeScreenLikeFrame(width: Int, height: Int, step: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        memset(base, 128, bytesPerRow * CVPixelBufferGetHeightOfPlane(buffer, plane))
        guard plane == 0 else { continue }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var seed = UInt32(truncatingIfNeeded: step &* 2_654_435_761 &+ 1)
        for y in 300..<900 {
            for x in (400 + step * 20)..<(1200 + step * 20) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                luma[y * bytesPerRow + x] = UInt8(seed >> 24)
            }
        }
    }
    return buffer
}
