#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import BridgeCore

private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private enum Posted: Equatable {
    case clipboard(String)
    case key(UInt16, isDown: Bool)
    case mouse(CGEventType)
}

/// Nothing here reaches the real system: events go to a recorder.
@Suite struct InputInjectorTests {
    private let display = DisplayInfo(id: 1, pointSize: CGSize(width: 1000, height: 500),
                                      pixelSize: CGSize(width: 2000, height: 1000), origin: .zero, isMain: true)

    private func makeInjector(_ log: Recorder<Posted>) -> InputInjector {
        InputInjector(display: display, writeClipboard: { log.append(.clipboard($0)) }, post: { event in
            if event.type == .keyDown || event.type == .keyUp {
                log.append(.key(UInt16(event.getIntegerValueField(.keyboardEventKeycode)), isDown: event.type == .keyDown))
            } else {
                log.append(.mouse(event.type))
            }
        })
    }

    @Test func stopReleasesHeldInputAndDropsLaterInput() {
        let log = Recorder<Posted>()
        let injector = makeInjector(log)
        injector.handle(.key(keyCode: 0, isDown: true, modifiers: 0))
        injector.handle(.mouseButton(button: .left, isDown: true, x: 0.5, y: 0.5, clickCount: 1))
        injector.stop()
        // Input that was still on its way when the session ended.
        injector.handle(.key(keyCode: 1, isDown: true, modifiers: 0))
        injector.handle(.mouseButton(button: .right, isDown: true, x: 0.5, y: 0.5, clickCount: 1))
        injector.drain()
        #expect(log.all == [
            .key(0, isDown: true), .mouse(.leftMouseDown),
            .key(0, isDown: false), .mouse(.leftMouseUp),
        ])
    }

    @Test func stopCanWaitForTheReleases() {
        let log = Recorder<Posted>()
        let injector = makeInjector(log)
        injector.handle(.key(keyCode: 2, isDown: true, modifiers: 0))
        injector.stop(waitUntilDone: true)
        #expect(log.all == [.key(2, isDown: true), .key(2, isDown: false)])
    }

    @Test func releaseAllKeepsTakingInput() {
        let log = Recorder<Posted>()
        let injector = makeInjector(log)
        injector.handle(.key(keyCode: 0, isDown: true, modifiers: 0))
        injector.releaseAll()
        injector.handle(.key(keyCode: 1, isDown: true, modifiers: 0))
        injector.drain()
        #expect(log.all == [.key(0, isDown: true), .key(0, isDown: false), .key(1, isDown: true)])
    }

    /// ⌘V follows the clipboard text: the text must be on the clipboard first.
    @Test(.timeLimit(.minutes(1))) func clipboardIsWrittenBeforeTheNextKey() async {
        let log = Recorder<Posted>()
        let injector = makeInjector(log)
        injector.handle(.clipboard(text: "pasted"))
        injector.handle(.key(keyCode: 9, isDown: true, modifiers: 0))
        // The write happens on the main queue: wait off it.
        await Task.detached { injector.drain() }.value
        #expect(log.all == [.clipboard("pasted"), .key(9, isDown: true)])
    }
}

private final class FakeStream {}

@Suite struct StreamSlotTests {
    // #expect cannot wrap a mutating call: results are taken first.

    @Test func aStartFinishingAfterAStopIsNotInstalled() {
        var slot = StreamSlot<FakeStream>()
        let start = slot.advance()
        _ = slot.advance() // stop() while ScreenCaptureKit was still starting
        let installed = slot.install(FakeStream(), generation: start.generation)
        #expect(!installed)
        #expect(slot.current == nil)
    }

    @Test func theLaterOfTwoStartsWins() {
        var slot = StreamSlot<FakeStream>()
        let first = slot.advance(), second = slot.advance()
        let a = FakeStream(), b = FakeStream()
        let installedB = slot.install(b, generation: second.generation)
        let installedA = slot.install(a, generation: first.generation)
        #expect(installedB && !installedA)
        #expect(slot.current === b)
    }

    @Test func aNewStartTakesOverTheRunningStream() {
        var slot = StreamSlot<FakeStream>()
        let a = FakeStream()
        let generation = slot.advance().generation
        let installed = slot.install(a, generation: generation)
        let next = slot.advance()
        #expect(installed)
        #expect(next.previous === a) // the caller stops it
        #expect(slot.current == nil)
    }

    @Test func onlyTheCurrentStreamEndsTheSession() {
        var slot = StreamSlot<FakeStream>()
        let old = FakeStream(), current = FakeStream()
        _ = slot.install(old, generation: slot.advance().generation)
        _ = slot.install(current, generation: slot.advance().generation)
        let removedOld = slot.remove(old) // stopped on purpose: its error is ignored
        #expect(!removedOld)
        #expect(slot.isCurrent(current))
        let removedCurrent = slot.remove(current)
        #expect(removedCurrent)
        #expect(slot.current == nil)
    }
}
#endif

@Suite struct StatsLogTests {
    @Test func candidatesAreLoggedWithoutAddresses() {
        let sdp = "candidate:842163049 1 udp 1677729535 203.0.113.7 61234 typ srflx raddr 192.168.1.20 rport 61234 generation 0"
        #expect(PeerSession.candidateType(sdp) == "srflx")
        #expect(PeerSession.kind(.candidate(sdp: sdp, mLineIndex: 0, mid: "0")) == "candidate srflx")
        #expect(PeerSession.candidateType("garbage") == "?")
    }

    @Test func logIsCappedWithOneOldCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbridge-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.log")
        let line = String(repeating: "x", count: 9) + "\n" // 10 bytes

        for _ in 0..<3 { PeerSession.appendLine(line, to: url, limit: 25) }
        #expect(try Data(contentsOf: url).count == 30)
        // At the limit: moved aside, a fresh file begins.
        PeerSession.appendLine(line, to: url, limit: 25)
        #expect(try Data(contentsOf: url).count == 10)
        let old = url.appendingPathExtension("1")
        #expect(try Data(contentsOf: old).count == 30)
        // The next rotation replaces the old copy: never more than two files.
        for _ in 0..<3 { PeerSession.appendLine(line, to: url, limit: 25) }
        #expect(try Data(contentsOf: url).count == 10)
        #expect(try Data(contentsOf: old).count == 30)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func closedSessionDropsItsCallbacks() async throws {
        let session = try #require(PeerSession(role: .host))
        session.onInput = { _ in }
        session.close()
        for _ in 0..<100 where session.onInput != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(session.onInput == nil)
        // Set after close: dropped, so it cannot hold anything alive.
        session.onState = { _ in }
        #expect(session.onState == nil)
    }
}
