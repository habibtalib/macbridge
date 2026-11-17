import AppKit
import Foundation
import Testing
@testable import BridgeCore

@MainActor @Suite struct ClipboardSyncTests {
    /// A private clipboard, so tests never touch the real one.
    private func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("macbridge-test-\(UUID().uuidString)")) }

    private func copy(_ text: String, to board: NSPasteboard, marks: [String] = []) {
        board.clearContents()
        board.setString(text, forType: .string)
        for mark in marks { board.setString("", forType: NSPasteboard.PasteboardType(mark)) }
    }

    @Test func sendsNewCopiesOnce() {
        let board = board()
        defer { board.releaseGlobally() }
        copy("already there", to: board)
        let sync = ClipboardSync(pasteboard: board)
        var sent: [String] = []
        sync.onLocalCopy = { sent.append($0) }
        sync.start()
        defer { sync.stop() }
        sync.poll()
        #expect(sent.isEmpty) // what was copied before the session stays here
        copy("hello", to: board)
        sync.poll()
        sync.poll()
        #expect(sent == ["hello"])
    }

    @Test func receivedTextIsNotSentBack() {
        let board = board()
        defer { board.releaseGlobally() }
        let sync = ClipboardSync(pasteboard: board)
        var sent: [String] = []
        sync.onLocalCopy = { sent.append($0) }
        sync.receive("from the other Mac")
        sync.poll()
        #expect(board.string(forType: .string) == "from the other Mac")
        #expect(sent.isEmpty)
        sync.receive("")
        #expect(board.string(forType: .string) == "from the other Mac")
    }

    @Test func twoMacsSettleWithoutEchoing() {
        let a = board(), b = board()
        defer { a.releaseGlobally(); b.releaseGlobally() }
        let onA = ClipboardSync(pasteboard: a), onB = ClipboardSync(pasteboard: b)
        var hops = 0
        onA.onLocalCopy = { hops += 1; onB.receive($0) }
        onB.onLocalCopy = { hops += 1; onA.receive($0) }
        copy("shared", to: a)
        for _ in 0..<5 { onA.poll(); onB.poll() }
        #expect(b.string(forType: .string) == "shared")
        #expect(hops == 1)
    }

    @Test func passwordManagerCopiesStayPut() {
        let board = board()
        defer { board.releaseGlobally() }
        let sync = ClipboardSync(pasteboard: board)
        var sent: [String] = []
        sync.onLocalCopy = { sent.append($0) }
        copy("hunter2", to: board, marks: ["org.nspasteboard.ConcealedType"])
        sync.poll()
        copy(String(repeating: "x", count: InputMessage.maxClipboardBytes + 1), to: board)
        sync.poll()
        #expect(sent.isEmpty)
    }
}

@Suite struct RemoteShortcutTests {
    @Test func desktopShortcutsAreControlArrowPresses() {
        let control = UInt32(CGEventFlags.maskControl.rawValue)
        let arrow = control | UInt32(CGEventFlags.maskSecondaryFn.rawValue)
        #expect(RemoteShortcut.nextDesktop.messages == [
            .key(keyCode: 59, isDown: true, modifiers: control),
            .key(keyCode: 124, isDown: true, modifiers: arrow),
            .key(keyCode: 124, isDown: false, modifiers: arrow),
            .key(keyCode: 59, isDown: false, modifiers: 0),
        ])
        #expect(RemoteShortcut.previousDesktop.messages[1] == .key(keyCode: 123, isDown: true, modifiers: arrow))
        #expect(RemoteShortcut.missionControl.messages[1] == .key(keyCode: 126, isDown: true, modifiers: arrow))
        let command = UInt32(CGEventFlags.maskCommand.rawValue)
        #expect(RemoteShortcut.spotlight.messages == [
            .key(keyCode: 55, isDown: true, modifiers: command),
            .key(keyCode: 49, isDown: true, modifiers: command),
            .key(keyCode: 49, isDown: false, modifiers: command),
            .key(keyCode: 55, isDown: false, modifiers: 0),
        ])
        #expect(RemoteShortcut.lockScreen.messages.count == 6)
        // Every shortcut lets go of what it pressed, in the reverse order, ending with nothing held.
        for shortcut in RemoteShortcut.allCases {
            let downs = shortcut.messages.compactMap { if case let .key(code, true, _) = $0 { code } else { nil } }
            let ups = shortcut.messages.compactMap { if case let .key(code, false, _) = $0 { code } else { nil } }
            #expect(downs == ups.reversed())
            guard case let .key(_, false, last) = shortcut.messages.last else { Issue.record("does not end with a key up"); continue }
            #expect(last == 0)
        }
    }
}
