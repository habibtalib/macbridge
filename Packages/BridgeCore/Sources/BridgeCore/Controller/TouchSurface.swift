#if os(iOS)
import SwiftUI
import UIKit
import WebRTC

/// How a finger on the picture moves the Mac's pointer.
public enum PointerMode: String, CaseIterable, Sendable {
    /// The pointer goes where the finger touches.
    case direct
    /// The finger moves the pointer by an amount, like a laptop trackpad.
    case trackpad
}

/// What the session screen's buttons share with the touch surface: the pointer mode, the on-screen
/// keyboard, modifier keys held from the key bar, and zoom.
@MainActor
public final class SessionInput: ObservableObject {
    @Published public var mode: PointerMode
    /// ⌘ ⌥ ⌃ ⇧ tapped on the key bar: held for the next key, then let go.
    @Published public var sticky: WireModifiers = []
    @Published public private(set) var keyboardVisible = false
    @Published public private(set) var isZoomed = false

    /// Where input goes; set by the session screen once it has its model.
    public var send: (InputMessage) -> Void
    weak var surface: TouchSurfaceView?

    public init(mode: PointerMode, send: @escaping (InputMessage) -> Void = { _ in }) {
        self.mode = mode
        self.send = send
    }

    public func showKeyboard() { surface?.becomeFirstResponder() }
    public func hideKeyboard() { surface?.resignFirstResponder() }
    public func toggleKeyboard() { keyboardVisible ? hideKeyboard() : showKeyboard() }
    public func resetZoom() { surface?.resetZoom() }

    func keyboardChanged(_ visible: Bool) { if keyboardVisible != visible { keyboardVisible = visible } }
    func zoomChanged(_ zoomed: Bool) { if isZoomed != zoomed { isZoomed = zoomed } }

    /// One key from the key bar (Esc, Tab, arrows…), with the sticky modifiers.
    public func press(_ keyCode: UInt16, holding extra: WireModifiers = []) {
        let held = sticky.union(extra)
        let order: [WireModifiers] = [.control, .option, .command, .shift]
        for message in InputMapping.keyPress(keyCode, holding: order.filter(held.contains),
                                             extra: MacKey.carriesFunctionFlag(keyCode) ? .function : []) {
            send(message)
        }
        sticky = []
    }

    /// Text from the on-screen keyboard. Characters that have no key on a US keyboard are pasted.
    public func type(_ text: String) {
        let typed = MacKey.typing(text, holding: sticky)
        typed.messages.forEach(send)
        if !typed.unmapped.isEmpty {
            send(.clipboard(text: typed.unmapped))
            InputMapping.keyPress(9, holding: [.command]).forEach(send) // ⌘V
        }
        sticky = []
    }
}

/// The remote screen with touch, pointer and keyboard input.
public struct TouchSurface: UIViewRepresentable {
    private let video: RemoteVideo
    private let input: SessionInput
    private let onVideoSize: (CGSize) -> Void

    public init(_ video: RemoteVideo, input: SessionInput, onVideoSize: @escaping (CGSize) -> Void = { _ in }) {
        self.video = video
        self.input = input
        self.onVideoSize = onVideoSize
    }

    public func makeUIView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView(track: video.track, input: input)
        view.onVideoSize = onVideoSize
        return view
    }

    public func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.onVideoSize = onVideoSize
    }

    public static func dismantleUIView(_ view: TouchSurfaceView, coordinator: ()) {
        view.detach()
    }
}

public final class TouchSurfaceView: UIView, UIKeyInput, UIScrollViewDelegate, UIGestureRecognizerDelegate, RTCVideoViewDelegate {
    private let input: SessionInput
    private var track: RTCVideoTrack?
    private let scroll = UIScrollView()
    private let videoView = RTCMTLVideoView(frame: .zero)
    private var videoSize = CGSize(width: 16, height: 10)
    var onVideoSize: (CGSize) -> Void = { _ in }

    private var pointer = TrackpadPointer()
    private var lastPan = CGPoint.zero
    private var lastScroll = CGPoint.zero
    private var lastTap: (time: TimeInterval, x: Float, y: Float)?
    private var dragging = false
    private var heldKeys: Set<UInt16> = []
    private var hardwareModifiers: WireModifiers = []
    private var twoFingerScroll: UIPanGestureRecognizer!

    init(track: RTCVideoTrack, input: SessionInput) {
        self.input = input
        self.track = track
        super.init(frame: .zero)
        backgroundColor = .black
        input.surface = self

        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        // One finger belongs to the Mac's pointer; two fingers move a zoomed picture.
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        addSubview(scroll)

        videoView.videoContentMode = .scaleAspectFit
        videoView.delegate = self
        videoView.isUserInteractionEnabled = false
        scroll.addSubview(videoView)
        track.add(videoView)

        addGestures()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func detach() {
        track?.remove(videoView)
        track = nil
        releaseEverything()
    }

    // MARK: Layout and zoom

    public override func layoutSubviews() {
        super.layoutSubviews()
        let old = scroll.bounds.size
        scroll.frame = bounds
        if old != bounds.size || videoView.bounds.isEmpty { fitVideo() } else { centre() }
    }

    /// Sizes the picture to fit the screen at zoom 1.
    private func fitVideo() {
        guard bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else { return }
        scroll.zoomScale = 1
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        videoView.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
        centre()
        input.zoomChanged(false)
    }

    private func centre() {
        let content = scroll.contentSize
        let x = max(0, (scroll.bounds.width - content.width) / 2), y = max(0, (scroll.bounds.height - content.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func resetZoom() { scroll.setZoomScale(1, animated: true) }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { videoView }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
        let zoomed = scrollView.zoomScale > 1.01
        // Zoomed in, two fingers move the picture; otherwise they scroll on the Mac.
        twoFingerScroll.isEnabled = !zoomed
        input.zoomChanged(zoomed)
    }

    public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async {
            guard size.width > 0, size.height > 0, size != self.videoSize else { return }
            self.videoSize = size
            self.fitVideo()
            self.onVideoSize(size)
        }
    }

    // MARK: Gestures

    private func addGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(secondaryTapped))
        twoFingerTap.numberOfTouchesRequired = 2
        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(secondaryTapped))
        secondaryClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        secondaryClick.buttonMaskRequired = .secondary
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        // Tap, then touch again and move: drag (trackpad mode).
        let tapAndHold = UILongPressGestureRecognizer(target: self, action: #selector(tapAndHeld))
        tapAndHold.numberOfTapsRequired = 1
        tapAndHold.minimumPressDuration = 0.08
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        twoFingerScroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        twoFingerScroll.minimumNumberOfTouches = 2
        twoFingerScroll.maximumNumberOfTouches = 2
        // A mouse wheel or a trackpad's two-finger scroll on an iPad.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered))

        tap.require(toFail: tapAndHold)
        for recognizer in [tap, twoFingerTap, secondaryClick, longPress, tapAndHold, pan, twoFingerScroll, wheel, hover] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    public func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        // Pinch (zoom) may run alongside ours; our own do not overlap.
        b === scroll.pinchGestureRecognizer || a === scroll.pinchGestureRecognizer
    }

    /// A mouse or trackpad pointer always points where it is; fingers follow the chosen mode.
    private func isDirect(_ recognizer: UIGestureRecognizer) -> Bool {
        input.mode == .direct || isIndirect
    }
    private var isIndirect = false

    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        isIndirect = touch.type == .indirectPointer
        return true
    }

    /// Where on the remote screen a gesture is, 0...1.
    private func spot(_ recognizer: UIGestureRecognizer) -> (x: Float, y: Float) {
        InputMapping.normalizedTopLeft(recognizer.location(in: videoView), in: videoView.bounds.size)
    }

    private func move(to spot: (x: Float, y: Float)) {
        pointer.set(x: spot.x, y: spot.y)
        input.send(.mouseMove(x: pointer.x, y: pointer.y))
    }

    private func click(_ button: MouseButton, count: UInt8 = 1) {
        input.send(.mouseButton(button: button, isDown: true, x: pointer.x, y: pointer.y, clickCount: count))
        input.send(.mouseButton(button: button, isDown: false, x: pointer.x, y: pointer.y, clickCount: count))
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if isDirect(recognizer) { move(to: spot(recognizer)) }
        // Two taps close together in time and place are a double click.
        let now = ProcessInfo.processInfo.systemUptime
        var count: UInt8 = 1
        if let last = lastTap, now - last.time < 0.4, abs(last.x - pointer.x) < 0.02, abs(last.y - pointer.y) < 0.02 { count = 2 }
        lastTap = count == 2 ? nil : (now, pointer.x, pointer.y)
        click(.left, count: count)
    }

    @objc private func secondaryTapped(_ recognizer: UITapGestureRecognizer) {
        if isDirect(recognizer) { move(to: spot(recognizer)) }
        click(.right)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, isDirect(recognizer) else { return }
        move(to: spot(recognizer))
        click(.right)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func tapAndHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard input.mode == .trackpad, !isIndirect else { return }
        drag(recognizer, relative: true)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        if isDirect(recognizer) {
            drag(recognizer, relative: false)
        } else {
            // Trackpad mode: one finger only moves the pointer.
            let point = recognizer.location(in: self)
            if recognizer.state == .began { lastPan = point; return }
            pointer.move(by: CGSize(width: point.x - lastPan.x, height: point.y - lastPan.y), shownSize: videoView.frame.size)
            lastPan = point
            input.send(.mouseMove(x: pointer.x, y: pointer.y))
        }
    }

    /// Press at the start, follow the finger, let go at the end.
    private func drag(_ recognizer: UIGestureRecognizer, relative: Bool) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPan = point
            if !relative { move(to: spot(recognizer)) }
            dragging = true
            input.send(.mouseButton(button: .left, isDown: true, x: pointer.x, y: pointer.y, clickCount: 1))
        case .changed:
            if relative {
                pointer.move(by: CGSize(width: point.x - lastPan.x, height: point.y - lastPan.y), shownSize: videoView.frame.size)
                input.send(.mouseMove(x: pointer.x, y: pointer.y))
            } else {
                move(to: spot(recognizer))
            }
            lastPan = point
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            input.send(.mouseButton(button: .left, isDown: false, x: pointer.x, y: pointer.y, clickCount: 1))
        default:
            break
        }
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        let now = recognizer.translation(in: self)
        if recognizer.state == .began { lastScroll = .zero }
        let dx = now.x - lastScroll.x, dy = now.y - lastScroll.y
        lastScroll = now
        guard dx != 0 || dy != 0 else { return }
        // Content follows the fingers, as on a Mac trackpad with natural scrolling.
        input.send(.scroll(dx: Float(dx * 2), dy: Float(dy * 2)))
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .changed || recognizer.state == .began else { return }
        move(to: spot(recognizer))
    }

    // MARK: On-screen keyboard

    public override var canBecomeFirstResponder: Bool { true }
    public var hasText: Bool { true }
    public func insertText(_ text: String) { input.type(text) }
    public func deleteBackward() { input.press(MacKey.delete) }

    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var keyboardType: UIKeyboardType = .asciiCapable

    @objc private func keyboardWillShow() { if isFirstResponder { input.keyboardChanged(true) } }
    @objc private func keyboardWillHide() { input.keyboardChanged(false) }

    // MARK: Hardware keyboard

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: true) { super.pressesBegan(presses, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: false) { super.pressesEnded(presses, with: event) }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: false) { super.pressesCancelled(presses, with: event) }
    }

    /// Sends hardware keys as they are, so shortcuts and held keys work. True if every press was a key.
    private func handle(_ presses: Set<UIPress>, isDown: Bool) -> Bool {
        var handled = !presses.isEmpty
        for press in presses {
            guard let key = press.key, let code = MacKey.keyCode(forHIDUsage: key.keyCode.rawValue) else { handled = false; continue }
            if let modifier = MacKey.modifier(forHIDUsage: key.keyCode.rawValue), modifier != .capsLock {
                if isDown { hardwareModifiers.insert(modifier) } else { hardwareModifiers.remove(modifier) }
            }
            if isDown { heldKeys.insert(code) } else { heldKeys.remove(code) }
            var flags = hardwareModifiers
            if MacKey.carriesFunctionFlag(code) { flags.insert(.function) }
            input.send(.key(keyCode: code, isDown: isDown, modifiers: flags.rawValue))
        }
        return handled
    }

    /// Nothing may stay held on the Mac when this screen goes away.
    func releaseEverything() {
        for code in heldKeys { input.send(.key(keyCode: code, isDown: false, modifiers: 0)) }
        heldKeys.removeAll()
        hardwareModifiers = []
        if dragging {
            dragging = false
            input.send(.mouseButton(button: .left, isDown: false, x: pointer.x, y: pointer.y, clickCount: 1))
        }
    }
}
#endif
