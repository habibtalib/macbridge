#if !os(macOS)
import CoreGraphics
import CoreVideo
import Foundation

// An iPhone or iPad cannot be controlled: iOS gives an app neither the whole screen nor a way to
// send input. These stand-ins let the shared model compile; every one of them says "not possible".

public typealias CGDirectDisplayID = UInt32

public struct DisplayInfo: Identifiable, Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let pointSize: CGSize
    public let pixelSize: CGSize
    public let origin: CGPoint
    public let isMain: Bool
}

public final class ScreenCapturer: @unchecked Sendable {
    public struct Unavailable: Error {}
    public func setOnFrame(_ handler: ((CVPixelBuffer, _ timestampNs: Int64) -> Void)?) {}
    public var onStop: ((Error?) -> Void)?
    public init() {}
    public static var hasPermission: Bool { false }
    @discardableResult public static func requestPermission() -> Bool { false }
    public static func displays() async throws -> [DisplayInfo] { [] }
    public func start(displayID: CGDirectDisplayID? = nil, maxPixelWidth: Int = 2560, maxPixelHeight: Int = 1600,
                      framesPerSecond: Int = 60) async throws -> DisplayInfo { throw Unavailable() }
    public func stop() async {}
}

public final class InputInjector: @unchecked Sendable {
    public init(display: DisplayInfo, writeClipboard: @escaping (String) -> Void = { _ in }) {}
    public static var hasPermission: Bool { false }
    @discardableResult public static func requestPermission() -> Bool { false }
    public func setDisplay(_ display: DisplayInfo) {}
    public func handle(_ message: InputMessage) {}
    public func releaseAll() {}
    public func stop(waitUntilDone: Bool = false) {}
}

@MainActor
public final class PowerAssertions {
    public init() {}
    public var keepSystemAwake = false
    public var keepDisplayAwake = false
    public func wakeDisplay() {}
}

public final class VirtualDisplay {
    public struct Unavailable: Error {}
    public let displayID: CGDirectDisplayID = 0
    public init() throws { throw Unavailable() }
    public func waitUntilOnline(timeout: TimeInterval = 3) async -> Bool { false }
}

public enum Headless {
    public static func needsVirtualDisplay() -> Bool { false }
    public static func needsVirtualDisplay(ignoring id: CGDirectDisplayID?) -> Bool { false }
}

public final class DisplayChangeWatcher {
    public init(onChange: @escaping (_ changed: [CGDirectDisplayID: Bool]) -> Void) {}
}

public enum LidAndPower {
    public static var hasLid: Bool { false }
    public static var isOnPowerAdapter: Bool { true }
    public static func isLidSleepDisabled() -> Bool { false }
}

@MainActor
public final class LidClosedKeeper {
    public init() {}
    public let isAvailable = false
    public var isHolding: Bool { false }
    public func update(shouldHold: Bool) {}
}
#endif
