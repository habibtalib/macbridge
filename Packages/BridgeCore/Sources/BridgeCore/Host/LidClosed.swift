import Foundation
#if os(macOS)
import IOKit
import IOKit.ps
#endif

/// What a laptop that allows control does when its lid is closed.
public enum LidClosedMode: String, CaseIterable, Sendable {
    /// Sleeps like any Mac; it cannot be reached until it is opened.
    case off
    /// Stays awake and reachable while on the power adapter. On battery it sleeps,
    /// except during a session that is already running.
    case onPower
    /// Stays awake and reachable on battery too.
    case always

    /// Whether the Mac should be held awake right now.
    public func shouldHold(allowsControl: Bool, isOnline: Bool, isOnPower: Bool, inSession: Bool) -> Bool {
        guard allowsControl, isOnline else { return false }
        switch self {
        case .off: return false
        case .onPower: return isOnPower || inSession
        case .always: return true
        }
    }
}

#if os(macOS)
/// Facts about this Mac's lid and power.
public enum LidAndPower {
    /// Macs with a lid report its state; desktops do not.
    public static var hasLid: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() != nil
    }

    /// `pmset`'s SleepDisabled: the Mac stays awake with the lid closed.
    public static func isLidSleepDisabled() -> Bool {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.split(separator: " ").last == "1" }
    }

    public static var isOnPowerAdapter: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }
}

/// Keeps a laptop awake with its lid closed, through LidAwake (`lidawake keepalive`).
///
/// macOS only lets an administrator switch off lid-close sleep. LidAwake already has that permission
/// and its own guards (battery floor, heat), which still apply to a hold from here.
@MainActor
public final class LidClosedKeeper {
    public static let reason = "MacBridge"
    /// How long each hold lasts, and how often it is renewed. If MacBridge quits or crashes, the hold
    /// runs out by itself.
    static let holdMinutes = 15
    static let renewAfter: TimeInterval = 8 * 60

    private let run: ([String]) -> Void
    private let now: () -> Date
    private let sleepAlreadyDisabled: () -> Bool
    private var heldAt: Date?
    /// Lid-close sleep was already off when the hold began (you turned LidAwake on yourself):
    /// it is then left as it was when the hold ends.
    private var wasOnBefore = false

    /// `run`: starts `lidawake` with these arguments. nil when LidAwake is not installed.
    public init(run: (([String]) -> Void)? = LidClosedKeeper.lidAwakeRunner(), now: @escaping () -> Date = Date.init,
                sleepAlreadyDisabled: @escaping () -> Bool = LidAndPower.isLidSleepDisabled) {
        self.run = run ?? { _ in }
        self.now = now
        self.sleepAlreadyDisabled = sleepAlreadyDisabled
        isAvailable = run != nil
    }

    /// False when LidAwake is not installed: nothing can be held.
    public let isAvailable: Bool
    public var isHolding: Bool { heldAt != nil }

    /// Call whenever the answer may have changed, and at least every few minutes.
    public func update(shouldHold: Bool) {
        guard isAvailable else { return }
        if shouldHold {
            if let heldAt, now().timeIntervalSince(heldAt) < Self.renewAfter { return }
            if heldAt == nil { wasOnBefore = sleepAlreadyDisabled() }
            heldAt = now()
            run(["keepalive", "\(Self.holdMinutes)m", "--reason", Self.reason])
        } else if heldAt != nil {
            heldAt = nil
            run(["release", "--reason", Self.reason])
            // A released hold alone leaves LidAwake on until its own rules end it, which can be
            // long after. MacBridge turned it on, so MacBridge turns it off.
            if !wasOnBefore { run(["off"]) }
        }
    }

    nonisolated public static func lidAwakePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/lidawake", "/opt/homebrew/bin/lidawake", "/usr/local/bin/lidawake"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated public static func lidAwakeRunner() -> (([String]) -> Void)? {
        guard let path = lidAwakePath() else { return nil }
        return { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}
#endif
