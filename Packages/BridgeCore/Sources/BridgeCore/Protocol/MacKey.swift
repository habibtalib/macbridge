import CoreGraphics
import Foundation

/// macOS virtual key codes (ANSI layout), which is what the wire format carries, and how to get to
/// them from an iPhone or iPad: from a hardware key's USB HID usage, or from a typed character.
public enum MacKey {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126

    private static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    private static let plain: [Character: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
        " ": 49, "\n": 36, "\r": 36, "\t": 48,
    ]
    /// The character each key gives with Shift, on a US keyboard.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The key that types this character on a US keyboard, and whether Shift is held.
    /// nil for characters that have no key (accents, emoji): those are sent as pasted text.
    public static func key(for character: Character) -> (keyCode: UInt16, shift: Bool)? {
        if let code = plain[character] { return (code, false) }
        if let base = shifted[character], let code = plain[base] { return (code, true) }
        let lower = Character(character.lowercased())
        if let code = letters[lower] { return (code, character != lower) }
        return nil
    }

    private static let hidLetters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6] // a…z
    private static let hidDigits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] // 1…9, 0
    private static let hidFunction: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] // F1…F12
    private static let hidOther: [Int: UInt16] = [
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42,
        0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44, 0x39: 57,
        0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
        0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
    ]

    /// The macOS key code for a USB HID keyboard usage (what a hardware keyboard on an iPad reports).
    public static func keyCode(forHIDUsage usage: Int) -> UInt16? {
        switch usage {
        case 0x04...0x1D: return hidLetters[usage - 0x04]
        case 0x1E...0x27: return hidDigits[usage - 0x1E]
        case 0x3A...0x45: return hidFunction[usage - 0x3A]
        default: return hidOther[usage]
        }
    }

    /// The modifier a modifier key's HID usage stands for.
    public static func modifier(forHIDUsage usage: Int) -> WireModifiers? {
        switch usage {
        case 0xE0, 0xE4: return .control
        case 0xE1, 0xE5: return .shift
        case 0xE2, 0xE6: return .option
        case 0xE3, 0xE7: return .command
        case 0x39: return .capsLock
        default: return nil
        }
    }

    /// Arrow and function keys carry the function flag on a Mac.
    public static func carriesFunctionFlag(_ keyCode: UInt16) -> Bool {
        (123...126).contains(keyCode) || hidFunction.contains(keyCode) || [115, 116, 117, 119, 121].contains(keyCode)
    }

    /// The messages that type a string: a key press per character, with Shift where needed and any
    /// extra modifiers held. Characters without a key are returned in `unmapped`.
    public static func typing(_ text: String, holding: WireModifiers = []) -> (messages: [InputMessage], unmapped: String) {
        var messages: [InputMessage] = [], unmapped = ""
        let order: [WireModifiers] = [.control, .option, .command, .shift]
        for character in text {
            guard let key = key(for: character) else { unmapped.append(character); continue }
            var held = holding
            if key.shift { held.insert(.shift) }
            messages += InputMapping.keyPress(key.keyCode, holding: order.filter(held.contains),
                                              extra: carriesFunctionFlag(key.keyCode) ? .function : [])
        }
        return (messages, unmapped)
    }
}

/// The remote pointer in trackpad mode: the finger moves it by an amount, it does not jump to the finger.
public struct TrackpadPointer: Equatable, Sendable {
    /// Position on the remote screen, 0...1 from the top left.
    public private(set) var x: Float
    public private(set) var y: Float

    public init(x: Float = 0.5, y: Float = 0.5) {
        self.x = x
        self.y = y
    }

    /// Moves by a finger movement in points, on a picture shown `shownSize` points large.
    /// Faster movements travel further, like a real trackpad.
    public mutating func move(by delta: CGSize, shownSize: CGSize, speed: CGFloat = 1.4) {
        guard shownSize.width > 0, shownSize.height > 0 else { return }
        let distance = (delta.width * delta.width + delta.height * delta.height).squareRoot()
        let boost = speed * (1 + min(distance / 12, 2.5)) // up to 3.5× for a quick flick
        x = min(max(x + Float(delta.width * boost / shownSize.width), 0), 1)
        y = min(max(y + Float(delta.height * boost / shownSize.height), 0), 1)
    }

    public mutating func set(x: Float, y: Float) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

extension InputMapping {
    /// A point in a view whose origin is the top left (UIKit) → 0...1 on the remote screen.
    public static func normalizedTopLeft(_ point: CGPoint, in size: CGSize) -> (x: Float, y: Float) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        return (Float(min(max(point.x / size.width, 0), 1)), Float(min(max(point.y / size.height, 0), 1)))
    }
}
