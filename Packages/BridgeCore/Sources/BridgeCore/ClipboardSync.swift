import AppKit

/// Keeps the clipboards of the two Macs in a session the same: text copied on
/// one is put on the other. Text only, up to `InputMessage.maxClipboardBytes`.
@MainActor
public final class ClipboardSync {
    private let pasteboard: NSPasteboard
    private var lastChange: Int
    private var timer: Timer?

    /// Text was copied on this Mac and should go to the other one.
    public var onLocalCopy: ((String) -> Void)?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChange = pasteboard.changeCount
    }

    /// Starts watching. What is on the clipboard already is not sent.
    public func start() {
        lastChange = pasteboard.changeCount
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Sends the clipboard if it changed since the last look.
    public func poll() {
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        guard let text = Self.shareableText(on: pasteboard) else { return }
        onLocalCopy?(text)
    }

    /// Puts text copied on the other Mac on this Mac's clipboard, without
    /// sending it back.
    public func receive(_ text: String) {
        guard !text.isEmpty, pasteboard.string(forType: .string) != text else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChange = pasteboard.changeCount
    }

    /// Marks used by password managers for copies that must not be kept or shared.
    private static let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"]

    /// The clipboard's text if it may be shared: not marked private by a
    /// password manager, not empty, and small enough for one message.
    public static func shareableText(on pasteboard: NSPasteboard) -> String? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: privateTypes) else { return nil }
        return InputMapping.clipboardText(pasteboard.string(forType: .string))
    }
}
