import CoreGraphics
import Foundation
import Testing
@testable import BridgeCore

@Suite struct HeadlessTests {
    private let builtin = Headless.ActiveDisplay(id: 1, isBuiltin: true)
    private let external = Headless.ActiveDisplay(id: 2, isBuiltin: false)

    @Test func lidOpenBuiltinIsEnough() {
        #expect(!Headless.needsVirtualDisplay(active: [builtin], lidClosed: false))
    }

    @Test func lidClosedBuiltinOnlyNeedsVirtual() {
        // macOS may still list the switched-off panel with the lid closed.
        #expect(Headless.needsVirtualDisplay(active: [builtin], lidClosed: true))
    }

    @Test func lidClosedWithMonitorIsEnough() {
        #expect(!Headless.needsVirtualDisplay(active: [builtin, external], lidClosed: true))
        #expect(!Headless.needsVirtualDisplay(active: [external], lidClosed: true))
    }

    @Test func noActiveDisplayNeedsVirtual() {
        #expect(Headless.needsVirtualDisplay(active: [], lidClosed: false))
    }

    @Test func modesAreHalvedForHiDPIAndEven() {
        let modes = VirtualDisplay.modes(pixelWidth: 2880, pixelHeight: 1800, hiDPI: true)
        #expect(modes.map(\.width) == [1440, 960, 720])
        #expect(modes.map(\.height) == [900, 600, 450])
    }
}

/// Creates a real display, so it runs only when asked:
/// MACBRIDGE_LIVE_DISPLAY=1 swift test --filter LiveVirtualDisplayTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACBRIDGE_LIVE_DISPLAY"] == "1"))
struct LiveVirtualDisplayTests {
    @Test func appearsAndGoesAway() async throws {
        var display: VirtualDisplay? = try VirtualDisplay(name: "MacBridge Test Display")
        let id = try #require(display?.displayID)
        let online = await display!.waitUntilOnline()
        #expect(online, "virtual display \(id) never came online")
        #expect(Headless.activeDisplays().contains { $0.id == id })
        let bounds = CGDisplayBounds(id)
        print("virtual display \(id): \(Int(bounds.width))x\(Int(bounds.height)) points, lid closed: \(Headless.isLidClosed)")
        display = nil
        for _ in 0..<30 where Headless.onlineDisplayIDs().contains(id) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(!Headless.onlineDisplayIDs().contains(id), "virtual display \(id) still online after release")
    }
}
