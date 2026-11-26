import Foundation

/// Messages sent from the controller to the host over the WebRTC data channels.
///
/// Wire format: `[version: u8][type: u8][payload]`, integers and floats big-endian.
/// Pointer positions are normalised to 0...1 across the captured display, so the
/// controller never needs to know the host's resolution or scale.
/// Key codes are macOS virtual key codes; both ends are Macs, so no mapping.
public enum InputMessage: Equatable, Sendable {
    case mouseMove(x: Float, y: Float)
    case mouseButton(button: MouseButton, isDown: Bool, x: Float, y: Float, clickCount: UInt8)
    case scroll(dx: Float, dy: Float)
    case key(keyCode: UInt16, isDown: Bool, modifiers: UInt32)
    case clipboard(text: String)
    /// Show the host's next display instead of the current one.
    case nextDisplay
    case quality(QualityPreset)
    /// Show this display of the host (an ID from the host's `displays` list).
    case selectDisplay(id: UInt32)
    /// Host to controller: the host's displays, and which one is being shown.
    case displays([RemoteDisplay])

    public static let protocolVersion: UInt8 = 1
    /// Largest clipboard text sent in one message; WebRTC data channel
    /// messages are limited in size.
    public static let maxClipboardBytes = 100_000

    /// Pointer moves and scrolls go on the unordered, no-retransmit channel:
    /// a late one is worthless, so it is dropped rather than queued.
    public var prefersUnreliableChannel: Bool {
        switch self {
        case .mouseMove, .scroll: return true
        case .mouseButton, .key, .clipboard, .nextDisplay, .quality, .selectDisplay, .displays: return false
        }
    }
}

/// One of the host's displays, as the controller's display menu shows it.
public struct RemoteDisplay: Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var name: String
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    public var isMain: Bool
    /// The display the session is showing.
    public var isCurrent: Bool

    public init(id: UInt32, name: String, pixelWidth: UInt32, pixelHeight: UInt32, isMain: Bool, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
        self.isCurrent = isCurrent
    }

    /// Longest name sent, in bytes; longer ones are cut.
    public static let maxNameBytes = 64
    public static let maxCount = 16
}

public enum MouseButton: UInt8, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

/// How much of the host's screen detail and motion to send.
public enum QualityPreset: UInt8, CaseIterable, Sendable {
    /// Full detail, smooth motion. For good connections.
    case sharp = 0
    case balanced = 1
    /// Smaller and slower, for weak connections.
    case light = 2

    public var maxPixelWidth: Int { [2560, 1920, 1280][Int(rawValue)] }
    public var maxPixelHeight: Int { [1600, 1200, 800][Int(rawValue)] }
    public var framesPerSecond: Int { [60, 30, 15][Int(rawValue)] }
}

public enum InputMessageError: Error, Equatable {
    case tooShort
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case unknownButton(UInt8)
    case invalidText
    /// Clipboard text over `InputMessage.maxClipboardBytes`.
    case tooLong
    case invalidCoordinate
    case unknownQuality(UInt8)
}

private enum MessageType: UInt8 {
    case mouseMove = 1
    case mouseButton = 2
    case scroll = 3
    case key = 4
    case clipboard = 5
    case nextDisplay = 6
    case quality = 7
    case selectDisplay = 8
    case displays = 9
}

extension InputMessage {
    public func encoded() -> Data {
        var w = Writer()
        w.u8(Self.protocolVersion)
        switch self {
        case let .mouseMove(x, y):
            w.u8(MessageType.mouseMove.rawValue)
            w.f32(x); w.f32(y)
        case let .mouseButton(button, isDown, x, y, clickCount):
            w.u8(MessageType.mouseButton.rawValue)
            w.u8(button.rawValue)
            w.u8(isDown ? 1 : 0)
            w.f32(x); w.f32(y)
            w.u8(clickCount)
        case let .scroll(dx, dy):
            w.u8(MessageType.scroll.rawValue)
            w.f32(dx); w.f32(dy)
        case let .key(keyCode, isDown, modifiers):
            w.u8(MessageType.key.rawValue)
            w.u16(keyCode)
            w.u8(isDown ? 1 : 0)
            w.u32(modifiers)
        case let .clipboard(text):
            w.u8(MessageType.clipboard.rawValue)
            w.data.append(Data(text.utf8))
        case .nextDisplay:
            w.u8(MessageType.nextDisplay.rawValue)
        case let .quality(preset):
            w.u8(MessageType.quality.rawValue)
            w.u8(preset.rawValue)
        case let .selectDisplay(id):
            w.u8(MessageType.selectDisplay.rawValue)
            w.u32(id)
        case let .displays(list):
            w.u8(MessageType.displays.rawValue)
            let list = list.prefix(RemoteDisplay.maxCount)
            w.u8(UInt8(list.count))
            for display in list {
                w.u32(display.id)
                w.u32(display.pixelWidth)
                w.u32(display.pixelHeight)
                w.u8((display.isMain ? 1 : 0) | (display.isCurrent ? 2 : 0))
                var name = Data(display.name.utf8.prefix(RemoteDisplay.maxNameBytes))
                // Never cut a character in half.
                while String(data: name, encoding: .utf8) == nil, !name.isEmpty { name.removeLast() }
                w.u8(UInt8(name.count))
                w.data.append(name)
            }
        }
        return w.data
    }

    public init(decoding data: Data) throws {
        var r = Reader(data)
        let version = try r.u8()
        guard version == Self.protocolVersion else {
            throw InputMessageError.unsupportedVersion(version)
        }
        let rawType = try r.u8()
        guard let type = MessageType(rawValue: rawType) else {
            throw InputMessageError.unknownType(rawType)
        }
        switch type {
        case .mouseMove:
            self = .mouseMove(x: try r.unit(), y: try r.unit())
        case .mouseButton:
            let rawButton = try r.u8()
            guard let button = MouseButton(rawValue: rawButton) else {
                throw InputMessageError.unknownButton(rawButton)
            }
            let isDown = try r.u8() != 0
            self = .mouseButton(
                button: button, isDown: isDown,
                x: try r.unit(), y: try r.unit(),
                clickCount: try r.u8()
            )
        case .scroll:
            self = .scroll(dx: try r.finite(), dy: try r.finite())
        case .key:
            let keyCode = try r.u16()
            let isDown = try r.u8() != 0
            self = .key(keyCode: keyCode, isDown: isDown, modifiers: try r.u32())
        case .clipboard:
            // The sender caps what it sends; a peer that does not is refused here, before
            // the text reaches the pasteboard.
            guard r.remaining <= Self.maxClipboardBytes else { throw InputMessageError.tooLong }
            guard let text = String(data: r.rest(), encoding: .utf8) else {
                throw InputMessageError.invalidText
            }
            self = .clipboard(text: text)
        case .nextDisplay:
            self = .nextDisplay
        case .quality:
            let raw = try r.u8()
            guard let preset = QualityPreset(rawValue: raw) else { throw InputMessageError.unknownQuality(raw) }
            self = .quality(preset)
        case .selectDisplay:
            self = .selectDisplay(id: try r.u32())
        case .displays:
            let count = Int(try r.u8())
            guard count <= RemoteDisplay.maxCount else { throw InputMessageError.tooShort }
            var list: [RemoteDisplay] = []
            for _ in 0..<count {
                let id = try r.u32(), width = try r.u32(), height = try r.u32(), flags = try r.u8()
                guard let name = String(data: try r.bytes(Int(try r.u8())), encoding: .utf8) else { throw InputMessageError.invalidText }
                list.append(RemoteDisplay(id: id, name: name, pixelWidth: width, pixelHeight: height,
                                          isMain: flags & 1 != 0, isCurrent: flags & 2 != 0))
            }
            self = .displays(list)
        }
    }
}

private struct Writer {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
}

private struct Reader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func u8() throws -> UInt8 {
        guard offset + 1 <= bytes.count else { throw InputMessageError.tooShort }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw InputMessageError.tooShort }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func u32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw InputMessageError.tooShort }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A float that must be a real number. The host acts on these values, so
    /// NaN and infinity from a broken or hostile peer are rejected here.
    mutating func finite() throws -> Float {
        let v = Float(bitPattern: try u32())
        guard v.isFinite else { throw InputMessageError.invalidCoordinate }
        return v
    }

    /// A normalised coordinate, clamped to 0...1.
    mutating func unit() throws -> Float {
        min(max(try finite(), 0), 1)
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard offset + count <= bytes.count else { throw InputMessageError.tooShort }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    var remaining: Int { bytes.count - offset }

    mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}
