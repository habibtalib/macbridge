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

    public static let protocolVersion: UInt8 = 1

    /// Pointer moves and scrolls go on the unordered, no-retransmit channel:
    /// a late one is worthless, so it is dropped rather than queued.
    public var prefersUnreliableChannel: Bool {
        switch self {
        case .mouseMove, .scroll: return true
        case .mouseButton, .key, .clipboard: return false
        }
    }
}

public enum MouseButton: UInt8, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

public enum InputMessageError: Error, Equatable {
    case tooShort
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case unknownButton(UInt8)
    case invalidText
    case invalidCoordinate
}

private enum MessageType: UInt8 {
    case mouseMove = 1
    case mouseButton = 2
    case scroll = 3
    case key = 4
    case clipboard = 5
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
            guard let text = String(data: r.rest(), encoding: .utf8) else {
                throw InputMessageError.invalidText
            }
            self = .clipboard(text: text)
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

    mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}
