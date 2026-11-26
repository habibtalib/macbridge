#if os(macOS)
import AppKit
import Carbon.HIToolbox
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
        /// What the host was told is held down. Released when this view loses the
        /// keyboard, or the up event would go to another app and the host would keep it pressed.
        private var keysDown: Set<UInt16> = []
        private var buttonsDown: Set<MouseButton> = []
        private var lastPosition: (x: Float, y: Float) = (0.5, 0.5)
        private var keyUpMonitor: Any?

        public override var acceptsFirstResponder: Bool { true }
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        deinit {
            if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
            releaseHeld()
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            releaseSystemShortcuts()
            releaseHeld()
            removeKeyUpMonitor()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            window.makeFirstResponder(self)
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
            if window.isKeyWindow { takeSystemShortcuts() }
            installKeyUpMonitor()
        }

        public override func resignFirstResponder() -> Bool {
            releaseHeld()
            return super.resignFirstResponder()
        }

        /// Sends the release of every key and button still held.
        private func releaseHeld() {
            for keyCode in keysDown {
                send(.key(keyCode: keyCode, isDown: false, modifiers: 0))
            }
            keysDown.removeAll()
            for button in buttonsDown {
                send(.mouseButton(button: button, isDown: false, x: lastPosition.x, y: lastPosition.y, clickCount: 1))
            }
            buttonsDown.removeAll()
        }

        /// A key pressed with ⌘ goes through `performKeyEquivalent`, and AppKit
        /// then never calls `keyUp`: the host would see ⌘C as C held down. The
        /// monitor sees the key-up before AppKit drops it.
        private func installKeyUpMonitor() {
            guard keyUpMonitor == nil else { return }
            keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.firstResponder === self, self.keysDown.contains(event.keyCode) else { return event }
                self.key(event, isDown: false)
                return nil
            }
        }

        private func removeKeyUpMonitor() {
            guard let keyUpMonitor else { return }
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }

        // MARK: System shortcuts

        /// While the session window is in front, macOS stops acting on its own
        /// shortcuts (Control-arrows, Mission Control, Spotlight), so they reach
        /// this view and go to the host. macOS only honours this for apps
        /// allowed under Accessibility; without it the toolbar buttons remain.
        private var shortcutToken: UnsafeMutableRawPointer?

        @objc private func windowBecameKey() { takeSystemShortcuts() }
        @objc private func windowResignedKey() {
            releaseSystemShortcuts()
            releaseHeld()
        }

        private func takeSystemShortcuts() {
            guard shortcutToken == nil else { return }
            shortcutToken = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled))
        }

        private func releaseSystemShortcuts() {
            guard let token = shortcutToken else { return }
            PopSymbolicHotKeyMode(token)
            shortcutToken = nil
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
            lastPosition = (x, y)
            send(.mouseMove(x: x, y: y))
        }

        private func button(_ button: MouseButton, isDown: Bool, _ event: NSEvent) {
            let (x, y) = InputMapping.normalized(convert(event.locationInWindow, from: nil), in: bounds.size)
            lastPosition = (x, y)
            if isDown { buttonsDown.insert(button) } else { buttonsDown.remove(button) }
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
            if isDown { keysDown.insert(event.keyCode) } else { keysDown.remove(event.keyCode) }
            send(.key(keyCode: event.keyCode, isDown: isDown, modifiers: InputMapping.wireModifiers(event.modifierFlags)))
        }
    }
}
#endif
