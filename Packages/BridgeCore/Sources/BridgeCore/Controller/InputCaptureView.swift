import AppKit
import SwiftUI

/// Transparent layer over the remote screen. While the pointer is over it and
/// it has keyboard focus, mouse and keyboard events are sent to the host
/// instead of acting on this Mac.
public struct InputCaptureView: NSViewRepresentable {
    private let send: (InputMessage) -> Void

    public init(send: @escaping (InputMessage) -> Void) {
        self.send = send
    }

    public func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.send = send
        return view
    }

    public func updateNSView(_ view: CaptureView, context: Context) {
        view.send = send
    }

    public final class CaptureView: NSView {
        var send: (InputMessage) -> Void = { _ in }
        private var trackingArea: NSTrackingArea?

        public override var acceptsFirstResponder: Bool { true }
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            window?.makeFirstResponder(self)
        }

        public override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        // MARK: Mouse

        public override func mouseMoved(with event: NSEvent) { move(event) }
        public override func mouseDragged(with event: NSEvent) { move(event) }
        public override func rightMouseDragged(with event: NSEvent) { move(event) }
        public override func otherMouseDragged(with event: NSEvent) { move(event) }

        public override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            button(.left, isDown: true, event)
        }
        public override func mouseUp(with event: NSEvent) { button(.left, isDown: false, event) }
        public override func rightMouseDown(with event: NSEvent) { button(.right, isDown: true, event) }
        public override func rightMouseUp(with event: NSEvent) { button(.right, isDown: false, event) }
        public override func otherMouseDown(with event: NSEvent) { button(.middle, isDown: true, event) }
        public override func otherMouseUp(with event: NSEvent) { button(.middle, isDown: false, event) }

        public override func scrollWheel(with event: NSEvent) {
            // Trackpads report pixels; a classic wheel reports lines.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let dx = Float(event.scrollingDeltaX * scale)
            let dy = Float(event.scrollingDeltaY * scale)
            guard dx != 0 || dy != 0 else { return }
            send(.scroll(dx: dx, dy: dy))
        }

        private func move(_ event: NSEvent) {
            let (x, y) = InputMapping.normalized(convert(event.locationInWindow, from: nil), in: bounds.size)
            send(.mouseMove(x: x, y: y))
        }

        private func button(_ button: MouseButton, isDown: Bool, _ event: NSEvent) {
            let (x, y) = InputMapping.normalized(convert(event.locationInWindow, from: nil), in: bounds.size)
            let clicks = UInt8(clamping: max(1, event.clickCount))
            send(.mouseButton(button: button, isDown: isDown, x: x, y: y, clickCount: clicks))
        }

        // MARK: Keyboard

        public override func keyDown(with event: NSEvent) { key(event, isDown: true) }
        public override func keyUp(with event: NSEvent) { key(event, isDown: false) }

        /// Command shortcuts (⌘Q, ⌘W, ⌘C…) would otherwise act on this app's
        /// menu. While the remote screen has focus they belong to the host.
        public override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else { return false }
            key(event, isDown: true)
            return true
        }

        public override func flagsChanged(with event: NSEvent) {
            guard let isDown = InputMapping.modifierIsDown(keyCode: event.keyCode, flags: event.modifierFlags) else {
                return
            }
            key(event, isDown: isDown)
        }

        private func key(_ event: NSEvent, isDown: Bool) {
            // ⌘V pastes what is on *this* Mac's clipboard: send it ahead of the key.
            if isDown, !event.isARepeat, InputMapping.isPaste(keyCode: event.keyCode, flags: event.modifierFlags),
               let text = InputMapping.clipboardText(NSPasteboard.general.string(forType: .string)) {
                send(.clipboard(text: text))
            }
            send(.key(keyCode: event.keyCode, isDown: isDown, modifiers: InputMapping.wireModifiers(event.modifierFlags)))
        }
    }
}

/// Pure conversions between AppKit events and the wire format.
public enum InputMapping {
    /// View coordinates (origin bottom-left) → 0...1 with the origin top-left.
    public static func normalized(_ point: CGPoint, in size: CGSize) -> (x: Float, y: Float) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(1 - point.y / size.height, 0), 1)
        return (Float(x), Float(y))
    }

    /// The modifier bits shared by AppKit and Core Graphics event flags.
    public static func wireModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        UInt32(truncatingIfNeeded: flags.intersection([.capsLock, .shift, .control, .option, .command, .function]).rawValue)
    }

    public static func isPaste(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 9 && flags.intersection([.command, .control, .option]) == .command
    }

    /// Clipboard text worth sending: present, not empty, and small enough
    /// for one message.
    public static func clipboardText(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= InputMessage.maxClipboardBytes else { return nil }
        return text
    }

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
}
