import CoreVideo
import Foundation
import Testing
import WebRTC
@testable import BridgeCore

/// Runs a host and a controller in one process, wired directly to each other,
/// so the whole WebRTC path is exercised without a server, a second Mac or
/// screen-recording permission.
@Suite(.serialized) struct PeerSessionTests {
    @Test(.timeLimit(.minutes(1)))
    func videoAndInputFlowBetweenHostAndController() async throws {
        let host = try #require(PeerSession(role: .host))
        let controller = try #require(PeerSession(role: .controller))
        defer { host.close(); controller.close() }

        host.onSignal = { controller.handle($0) }
        controller.onSignal = { host.handle($0) }

        let received = Box<[InputMessage]>([])
        host.onInput = { message in received.update { $0.append(message) } }

        let renderer = FrameCounter()
        controller.onRemoteVideoTrack = { $0.add(renderer) }

        let inputReady = Box(false)
        controller.onInputReady = { inputReady.update { $0 = true } }

        host.start()

        // Video: push synthetic frames until some come out the other end.
        let buffer = try #require(makeFrame(width: 640, height: 360))
        let start = DispatchTime.now().uptimeNanoseconds
        try await poll("decoded frames on the controller") {
            host.push(buffer, timestampNs: Int64(DispatchTime.now().uptimeNanoseconds - start))
            return renderer.count >= 5
        }
        #expect(renderer.size == CGSize(width: 640, height: 360))

        // Input: both channels deliver to the host.
        try await poll("input channels open") { inputReady.value }
        let sent: [InputMessage] = [
            .key(keyCode: 0x00, isDown: true, modifiers: 0),
            .key(keyCode: 0x00, isDown: false, modifiers: 0),
            .mouseButton(button: .left, isDown: true, x: 0.5, y: 0.5, clickCount: 1),
            .clipboard(text: "hello"),
        ]
        for message in sent { #expect(controller.send(message)) }
        try await poll("reliable input on the host") { received.value.count >= sent.count }
        #expect(received.value == sent) // ordered channel keeps the order

        #expect(controller.send(.mouseMove(x: 0.25, y: 0.75)))
        try await poll("pointer move on the host") { received.value.contains(.mouseMove(x: 0.25, y: 0.75)) }

        // The stream is hardware H.264 at the size that was pushed.
        let stats = Box<[[String: String]]>([])
        host.videoStats { report in stats.update { $0 = report } }
        try await poll("video stats") { !stats.value.isEmpty }
        let outbound = try #require(stats.value.first)
        #expect(outbound["encoderImplementation"] == "VideoToolbox")
        #expect(outbound["frameWidth"] == "640")
    }

    @Test func hostIgnoresMalformedInput() throws {
        // Decoding is the gate in front of the host; garbage never becomes an event.
        #expect(throws: (any Error).self) { try InputMessage(decoding: Data([0xDE, 0xAD])) }
    }
}

private func poll(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(33))
    }
    Issue.record("timed out waiting for \(what)")
    throw CancellationError()
}

private func makeFrame(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
            let size = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 128, size)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private final class FrameCounter: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _size = CGSize.zero

    var count: Int { lock.withLock { _count } }
    var size: CGSize { lock.withLock { _size } }

    func setSize(_ size: CGSize) { lock.withLock { _size = size } }
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.withLock { _count += 1 }
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&_value) } }
}
