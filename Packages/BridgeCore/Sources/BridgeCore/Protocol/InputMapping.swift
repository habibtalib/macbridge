import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#endif

/// The modifier keys as the wire format carries them: the same bits macOS uses in its event flags,
/// written out here so the iPhone and iPad app can produce them too.
public struct WireModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let capsLock = WireModifiers(rawValue: 1 << 16)
    public static let shift = WireModifiers(rawValue: 1 << 17)
    public static let control = WireModifiers(rawValue: 1 << 18)
    public static let option = WireModifiers(rawValue: 1 << 19)
    public static let command = WireModifiers(rawValue: 1 << 20)
    /// Set by macOS on arrow and function keys.
    public static let function = WireModifiers(rawValue: 1 << 23)

    /// The modifier key's own key code (the left-hand one).
    public var keyCode: UInt16? {
        switch self {
        case .capsLock: return 57
        case .shift: return 56
        case .control: return 59
        case .option: return 58
        case .command: return 55
        case .function: return 63
        default: return nil
        }
    }
}

/// Shortcuts macOS acts on before an app sees them, sent to the host from the session window's menu.
public enum RemoteShortcut: CaseIterable, Sendable {
    case previousDesktop, nextDesktop, missionControl, spotlight, appSwitcher, lockScreen

    /// The key, the modifier keys held with it, and flags the key itself carries.
    private var keys: (keyCode: UInt16, modifiers: [WireModifiers], extra: WireModifiers) {
        switch self {
        case .previousDesktop: return (123, [.control], .function) // ⌃←
        case .nextDesktop: return (124, [.control], .function)     // ⌃→
        case .missionControl: return (126, [.control], .function)  // ⌃↑
        case .spotlight: return (49, [.command], [])               // ⌘Space
        case .appSwitcher: return (48, [.command], [])             // ⌘Tab: the app used before this one
        case .lockScreen: return (12, [.control, .command], [])    // ⌃⌘Q
        }
    }

    public var messages: [InputMessage] {
        InputMapping.keyPress(keys.keyCode, holding: keys.modifiers, extra: keys.extra)
    }
}

/// Pure conversions between AppKit events and the wire format.
public enum InputMapping {
    /// One press of a key with modifier keys held: modifiers down one by one, the key down and up,
    /// modifiers up again in reverse. What a keyboard would send.
    public static func keyPress(_ keyCode: UInt16, holding modifiers: [WireModifiers] = [], extra: WireModifiers = []) -> [InputMessage] {
        var held: WireModifiers = []
        var out: [InputMessage] = []
        for modifier in modifiers {
            held.insert(modifier)
            if let code = modifier.keyCode { out.append(.key(keyCode: code, isDown: true, modifiers: held.rawValue)) }
        }
        let withKey = held.union(extra).rawValue
        out.append(.key(keyCode: keyCode, isDown: true, modifiers: withKey))
        out.append(.key(keyCode: keyCode, isDown: false, modifiers: withKey))
        for modifier in modifiers.reversed() {
            held.remove(modifier)
            if let code = modifier.keyCode { out.append(.key(keyCode: code, isDown: false, modifiers: held.rawValue)) }
        }
        return out
    }

    /// View coordinates (origin bottom-left) → 0...1 with the origin top-left.
    public static func normalized(_ point: CGPoint, in size: CGSize) -> (x: Float, y: Float) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(1 - point.y / size.height, 0), 1)
        return (Float(x), Float(y))
    }

#if os(macOS)
    /// The modifier bits shared by AppKit and Core Graphics event flags.
    public static func wireModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        UInt32(truncatingIfNeeded: flags.intersection([.capsLock, .shift, .control, .option, .command, .function]).rawValue)
    }
#endif

#if os(macOS)
    public static func isPaste(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 9 && flags.intersection([.command, .control, .option]) == .command
    }
#endif

    /// Clipboard text worth sending: present, not empty, and small enough
    /// for one message.
    public static func clipboardText(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= InputMessage.maxClipboardBytes else { return nil }
        return text
    }

#if os(macOS)
    /// For a modifier key's own key code: whether that key is now held.
    /// Returns nil for key codes that are not modifiers.
    public static func modifierIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        switch keyCode {
        case 54, 55: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 57: return flags.contains(.capsLock)
        case 63: return flags.contains(.function)
        default: return nil
        }
    }
#endif
}
