import CoreGraphics
import Foundation
import Testing
@testable import BridgeCore

@Suite struct MacKeyTests {
    @Test func charactersMapToUSKeys() {
        #expect(MacKey.key(for: "a")! == (0, false))
        #expect(MacKey.key(for: "A")! == (0, true))
        #expect(MacKey.key(for: "z")! == (6, false))
        #expect(MacKey.key(for: "5")! == (23, false))
        #expect(MacKey.key(for: "%")! == (23, true))
        #expect(MacKey.key(for: "?")! == (44, true))
        #expect(MacKey.key(for: "\n")! == (36, false))
        #expect(MacKey.key(for: " ")! == (49, false))
        #expect(MacKey.key(for: "é") == nil)
        #expect(MacKey.key(for: "👋") == nil)
        // Every letter and every printable ASCII character has a key, and no two unshifted ones share it.
        let printable = (33...126).map { Character(UnicodeScalar($0)) }
        #expect(printable.allSatisfy { MacKey.key(for: $0) != nil })
        let unshifted = printable.compactMap { MacKey.key(for: $0) }.filter { !$0.shift }.map(\.keyCode)
        #expect(Set(unshifted).count == unshifted.count)
    }

    @Test func hardwareKeysMapFromHIDUsages() {
        #expect(MacKey.keyCode(forHIDUsage: 0x04) == 0)    // a
        #expect(MacKey.keyCode(forHIDUsage: 0x1D) == 6)    // z
        #expect(MacKey.keyCode(forHIDUsage: 0x1E) == 18)   // 1
        #expect(MacKey.keyCode(forHIDUsage: 0x27) == 29)   // 0
        #expect(MacKey.keyCode(forHIDUsage: 0x28) == 36)   // return
        #expect(MacKey.keyCode(forHIDUsage: 0x29) == 53)   // escape
        #expect(MacKey.keyCode(forHIDUsage: 0x4F) == 124)  // right arrow
        #expect(MacKey.keyCode(forHIDUsage: 0x52) == 126)  // up arrow
        #expect(MacKey.keyCode(forHIDUsage: 0x3A) == 122)  // F1
        #expect(MacKey.keyCode(forHIDUsage: 0x45) == 111)  // F12
        #expect(MacKey.keyCode(forHIDUsage: 0xE3) == 55)   // left command
        #expect(MacKey.keyCode(forHIDUsage: 0xE7) == 54)   // right command
        #expect(MacKey.keyCode(forHIDUsage: 0x00) == nil)
        #expect(MacKey.keyCode(forHIDUsage: 0x999) == nil)
        // A HID letter and the same typed letter end on the same key.
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            #expect(MacKey.keyCode(forHIDUsage: 0x04 + offset) == MacKey.key(for: letter)?.keyCode, "\(letter)")
        }
        for (offset, digit) in "1234567890".enumerated() {
            #expect(MacKey.keyCode(forHIDUsage: 0x1E + offset) == MacKey.key(for: digit)?.keyCode, "\(digit)")
        }
        #expect(MacKey.modifier(forHIDUsage: 0xE1) == .shift)
        #expect(MacKey.modifier(forHIDUsage: 0xE6) == .option)
        #expect(MacKey.modifier(forHIDUsage: 0x04) == nil)
    }

    @Test func wireModifiersAreTheMacEventFlagBits() {
        #expect(WireModifiers.shift.rawValue == UInt32(CGEventFlags.maskShift.rawValue))
        #expect(WireModifiers.control.rawValue == UInt32(CGEventFlags.maskControl.rawValue))
        #expect(WireModifiers.option.rawValue == UInt32(CGEventFlags.maskAlternate.rawValue))
        #expect(WireModifiers.command.rawValue == UInt32(CGEventFlags.maskCommand.rawValue))
        #expect(WireModifiers.capsLock.rawValue == UInt32(CGEventFlags.maskAlphaShift.rawValue))
        #expect(WireModifiers.function.rawValue == UInt32(CGEventFlags.maskSecondaryFn.rawValue))
    }

    @Test func typingHoldsShiftOnlyWhereNeeded() {
        let shift = WireModifiers.shift.rawValue
        let typed = MacKey.typing("aB")
        #expect(typed.unmapped.isEmpty)
        #expect(typed.messages == [
            .key(keyCode: 0, isDown: true, modifiers: 0), .key(keyCode: 0, isDown: false, modifiers: 0),
            .key(keyCode: 56, isDown: true, modifiers: shift),
            .key(keyCode: 11, isDown: true, modifiers: shift), .key(keyCode: 11, isDown: false, modifiers: shift),
            .key(keyCode: 56, isDown: false, modifiers: 0),
        ])
        // A sticky ⌘ from the key bar turns "c" into ⌘C.
        let command = WireModifiers.command.rawValue
        #expect(MacKey.typing("c", holding: .command).messages == [
            .key(keyCode: 55, isDown: true, modifiers: command),
            .key(keyCode: 8, isDown: true, modifiers: command), .key(keyCode: 8, isDown: false, modifiers: command),
            .key(keyCode: 55, isDown: false, modifiers: 0),
        ])
        #expect(MacKey.typing("né").unmapped == "é")
    }
}

@Suite struct TrackpadPointerTests {
    @Test func movesRelativelyAndStaysOnTheScreen() {
        var pointer = TrackpadPointer()
        #expect(pointer.x == 0.5 && pointer.y == 0.5)
        pointer.move(by: CGSize(width: 10, height: 0), shownSize: CGSize(width: 400, height: 250))
        #expect(pointer.x > 0.5 && pointer.y == 0.5)
        let slow = pointer.x - 0.5
        // The same distance in one quick movement goes further than in ten slow ones.
        var quick = TrackpadPointer(), steady = TrackpadPointer()
        quick.move(by: CGSize(width: 40, height: 0), shownSize: CGSize(width: 400, height: 250))
        for _ in 0..<4 { steady.move(by: CGSize(width: 10, height: 0), shownSize: CGSize(width: 400, height: 250)) }
        #expect(quick.x > steady.x)
        #expect(abs(steady.x - (0.5 + 4 * slow)) < 0.0001)
        // Never off the edge.
        pointer.move(by: CGSize(width: 100_000, height: -100_000), shownSize: CGSize(width: 400, height: 250))
        #expect(pointer.x == 1 && pointer.y == 0)
        pointer.move(by: CGSize(width: 5, height: 5), shownSize: .zero)
        #expect(pointer.x == 1 && pointer.y == 0)
        pointer.set(x: -3, y: 9)
        #expect(pointer.x == 0 && pointer.y == 1)
    }

    @Test func uiKitPointsMapWithoutFlipping() {
        let size = CGSize(width: 200, height: 100)
        #expect(InputMapping.normalizedTopLeft(CGPoint(x: 0, y: 0), in: size) == (0, 0))
        #expect(InputMapping.normalizedTopLeft(CGPoint(x: 50, y: 75), in: size) == (0.25, 0.75))
        #expect(InputMapping.normalizedTopLeft(CGPoint(x: 900, y: -5), in: size) == (1, 0))
        #expect(InputMapping.normalizedTopLeft(CGPoint(x: 1, y: 1), in: .zero) == (0, 0))
    }
}
