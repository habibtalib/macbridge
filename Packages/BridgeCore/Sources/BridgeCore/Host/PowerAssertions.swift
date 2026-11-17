#if os(macOS)
import Foundation
import IOKit.pwr_mgt

/// Keeps this Mac reachable and its screen on while that is needed.
///
/// - `keepSystemAwake`: stops idle sleep so the Mac stays online for incoming
///   sessions. The display may still turn off. Does not override a closed lid
///   on battery or a manual Sleep.
/// - `keepDisplayAwake`: held during a session; a sleeping display produces no
///   frames to capture.
@MainActor
public final class PowerAssertions {
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    private var activityAssertion = IOPMAssertionID(0)

    public init() {}

    public var keepSystemAwake = false {
        didSet {
            guard keepSystemAwake != oldValue else { return }
            systemAssertion = update(systemAssertion, hold: keepSystemAwake,
                                     type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                                     reason: "MacBridge is waiting for remote control sessions")
        }
    }

    public var keepDisplayAwake = false {
        didSet {
            guard keepDisplayAwake != oldValue else { return }
            displayAssertion = update(displayAssertion, hold: keepDisplayAwake,
                                      type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                      reason: "MacBridge remote control session")
            if keepDisplayAwake { wakeDisplay() }
        }
    }

    /// Turns the display on, as a key press would.
    public func wakeDisplay() {
        // The system expires this by itself; passing the same ID again extends it.
        IOPMAssertionDeclareUserActivity("MacBridge remote control session" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }

    private func update(_ current: IOPMAssertionID?, hold: Bool, type: String, reason: String) -> IOPMAssertionID? {
        if let current { IOPMAssertionRelease(current) }
        guard hold else { return nil }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }
}
#endif
