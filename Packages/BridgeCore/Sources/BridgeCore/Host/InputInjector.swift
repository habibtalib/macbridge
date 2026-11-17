#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Turns input messages from the controller into real mouse and keyboard
/// events on this Mac. Needs the Accessibility permission.
public final class InputInjector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macbridge.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)

    // Guarded by `queue`.
    private var display: DisplayInfo
    private var buttonsDown: Set<MouseButton> = []
    private var keysDown: Set<UInt16> = []
    private var flags: CGEventFlags = []
    private var lastPoint: CGPoint

    public init(display: DisplayInfo) {
        self.display = display
        lastPoint = CGPoint(x: display.origin.x + display.pointSize.width / 2,
                            y: display.origin.y + display.pointSize.height / 2)
    }

    public static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to System Settings.
    @discardableResult
    public static func requestPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Points later events at another display (after the capture switched).
    public func setDisplay(_ display: DisplayInfo) {
        queue.async { self.display = display }
    }

    public func handle(_ message: InputMessage) {
        queue.async { self.inject(message) }
    }

    /// Lets go of everything the controller was holding, so a dropped
    /// connection cannot leave a key or button stuck down.
    public func releaseAll() {
        queue.async {
            for key in self.keysDown {
                self.postKey(key, isDown: false, flags: [])
            }
            self.keysDown.removeAll()
            self.flags = []
            for button in self.buttonsDown {
                self.postMouse(Self.buttonEvent(button, isDown: false), at: self.lastPoint, button: button)
            }
            self.buttonsDown.removeAll()
        }
    }

    // MARK: - Injection

    private func inject(_ message: InputMessage) {
        switch message {
        case let .mouseMove(x, y):
            lastPoint = point(x, y)
            let held = Self.dragOrder.first(where: buttonsDown.contains)
            postMouse(held.map(Self.dragEvent) ?? .mouseMoved, at: lastPoint, button: held ?? .left)

        case let .mouseButton(button, isDown, x, y, clickCount):
            lastPoint = point(x, y)
            if isDown { buttonsDown.insert(button) } else { buttonsDown.remove(button) }
            postMouse(Self.buttonEvent(button, isDown: isDown), at: lastPoint, button: button,
                      clickCount: Int64(max(1, clickCount)))

        case let .scroll(dx, dy):
            guard let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Self.clampedInt32(dy), wheel2: Self.clampedInt32(dx), wheel3: 0
            ) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)

        case let .key(keyCode, isDown, modifiers):
            flags = CGEventFlags(rawValue: UInt64(modifiers)).intersection(Self.modifierMask)
            if isDown { keysDown.insert(keyCode) } else { keysDown.remove(keyCode) }
            postKey(keyCode, isDown: isDown, flags: flags)

        case let .clipboard(text):
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }

        case .nextDisplay, .quality, .selectDisplay, .displays:
            break // capture settings, handled by the session owner
        }
    }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        // Stay one point inside the far edges so the pointer never lands on
        // a neighbouring display.
        let px = min(CGFloat(x) * display.pointSize.width, display.pointSize.width - 1)
        let py = min(CGFloat(y) * display.pointSize.height, display.pointSize.height - 1)
        return CGPoint(x: display.origin.x + max(0, px), y: display.origin.y + max(0, py))
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: MouseButton, clickCount: Int64 = 1) {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
            mouseButton: Self.cgButton(button)
        ) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postKey(_ keyCode: UInt16, isDown: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { return }
        var flags = flags
        // Real arrow keys carry these two marks; macOS expects them on Control-arrow (switch desktop).
        if (123...126).contains(keyCode) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mapping

    private static let modifierMask: CGEventFlags = [
        .maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
    ]
    private static let dragOrder: [MouseButton] = [.left, .right, .middle]

    private static func cgButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    private static func buttonEvent(_ button: MouseButton, isDown: Bool) -> CGEventType {
        switch button {
        case .left: return isDown ? .leftMouseDown : .leftMouseUp
        case .right: return isDown ? .rightMouseDown : .rightMouseUp
        case .middle: return isDown ? .otherMouseDown : .otherMouseUp
        }
    }

    private static func dragEvent(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    private static func clampedInt32(_ value: Float) -> Int32 {
        Int32(max(-10_000, min(10_000, value.rounded())))
    }
}
#endif
