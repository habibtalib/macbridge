import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation
import IOKit

/// A display that exists only in software, so a Mac with its lid closed and no
/// monitor attached still has a screen to draw on and to capture.
///
/// The display lives as long as this object: releasing it removes the display
/// and macOS moves its windows back to a real one.
///
/// Built on CoreGraphics' private `CGVirtualDisplay` classes (see the
/// `CGVirtualDisplayPrivate` target). They are undocumented, so creation can
/// fail after a macOS update; callers fall back to the physical display.
public final class VirtualDisplay {
    public let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay

    public enum Failure: Error, Equatable {
        case unavailable
        case settingsRejected
    }

    /// - Parameters:
    ///   - pixelWidth, pixelHeight: largest mode, in physical pixels.
    ///   - hiDPI: offer Retina (2×) modes, so 2880×1800 pixels is a
    ///     1440×900-point desktop with sharp text.
    public init(name: String = "MacBridge Display",
                pixelWidth: Int = 2880, pixelHeight: Int = 1800,
                hiDPI: Bool = true) throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.queue = DispatchQueue.main
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        // Physical size only sets the reported DPI: a 15" 16:10 panel.
        descriptor.sizeInMillimeters = CGSize(width: 336, height: 210)
        descriptor.vendorID = 0x4D42 // "MB"
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { throw Failure.unavailable }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = Self.modes(pixelWidth: pixelWidth, pixelHeight: pixelHeight, hiDPI: hiDPI)
        guard display.apply(settings) else { throw Failure.settingsRejected }

        self.display = display
        displayID = display.displayID
    }

    /// The largest mode first, then smaller ones with the same aspect ratio.
    /// With HiDPI the system offers each as a 2× (points = pixels / 2) mode.
    static func modes(pixelWidth: Int, pixelHeight: Int, hiDPI: Bool) -> [CGVirtualDisplayMode] {
        let divisor = hiDPI ? 2 : 1
        let base = [(pixelWidth, pixelHeight), (pixelWidth * 2 / 3, pixelHeight * 2 / 3), (pixelWidth / 2, pixelHeight / 2)]
        return base
            .map { ($0.0 / divisor & ~1, $0.1 / divisor & ~1) }
            .filter { $0.0 >= 640 && $0.1 >= 400 }
            .map { CGVirtualDisplayMode(width: UInt($0.0), height: UInt($0.1), refreshRate: 60) }
    }

    /// Waits until the display shows up in the online display list, which
    /// takes a moment after creation. Returns false on timeout.
    public func waitUntilOnline(timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Headless.onlineDisplayIDs().contains(displayID) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return Headless.onlineDisplayIDs().contains(displayID)
    }
}

/// Decides whether this Mac has a screen worth capturing.
public enum Headless {
    public struct ActiveDisplay: Equatable, Sendable {
        public let id: CGDirectDisplayID
        public let isBuiltin: Bool
        public init(id: CGDirectDisplayID, isBuiltin: Bool) {
            self.id = id
            self.isBuiltin = isBuiltin
        }
    }

    /// True when nothing would be visible: no active display at all, or only
    /// the built-in panel while the lid is closed (it is switched off then,
    /// although macOS may still list it).
    public static func needsVirtualDisplay(active: [ActiveDisplay], lidClosed: Bool) -> Bool {
        let usable = active.filter { !(lidClosed && $0.isBuiltin) }
        return usable.isEmpty
    }

    public static func needsVirtualDisplay() -> Bool {
        needsVirtualDisplay(active: activeDisplays(), lidClosed: isLidClosed)
    }

    /// `AppleClamshellState` of the power-management root domain; false on
    /// Macs without a lid.
    public static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    public static func activeDisplays() -> [ActiveDisplay] {
        displayList(CGGetActiveDisplayList).map { ActiveDisplay(id: $0, isBuiltin: CGDisplayIsBuiltin($0) != 0) }
    }

    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        displayList(CGGetOnlineDisplayList)
    }

    private static func displayList(
        _ get: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard get(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard get(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
