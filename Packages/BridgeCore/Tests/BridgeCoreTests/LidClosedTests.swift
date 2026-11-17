import Foundation
import Testing
@testable import BridgeCore

@Suite struct LidClosedModeTests {
    @Test func holdsOnlyWhenReachableAndWanted() {
        // Never when control is off or the Mac is offline.
        for mode in LidClosedMode.allCases {
            #expect(!mode.shouldHold(allowsControl: false, isOnline: true, isOnPower: true, inSession: false))
            #expect(!mode.shouldHold(allowsControl: true, isOnline: false, isOnPower: true, inSession: false))
        }
        #expect(!LidClosedMode.off.shouldHold(allowsControl: true, isOnline: true, isOnPower: true, inSession: true))
        #expect(LidClosedMode.onPower.shouldHold(allowsControl: true, isOnline: true, isOnPower: true, inSession: false))
        #expect(!LidClosedMode.onPower.shouldHold(allowsControl: true, isOnline: true, isOnPower: false, inSession: false))
        // Unplugging in the middle of a session does not cut it off.
        #expect(LidClosedMode.onPower.shouldHold(allowsControl: true, isOnline: true, isOnPower: false, inSession: true))
        #expect(LidClosedMode.always.shouldHold(allowsControl: true, isOnline: true, isOnPower: false, inSession: false))
    }
}

@MainActor @Suite struct LidClosedKeeperTests {
    @Test func holdsRenewsAndReleases() {
        var calls: [[String]] = []
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let keeper = LidClosedKeeper(run: { calls.append($0) }, now: { clock }, sleepAlreadyDisabled: { false })

        keeper.update(shouldHold: false)
        #expect(calls.isEmpty) // nothing to release

        keeper.update(shouldHold: true)
        #expect(calls == [["keepalive", "15m", "--reason", "MacBridge"]])
        #expect(keeper.isHolding)

        // Asked again a minute later: the hold is still fresh.
        clock += 60
        keeper.update(shouldHold: true)
        #expect(calls.count == 1)

        // Renewed well before the 15 minutes run out.
        clock += 8 * 60
        keeper.update(shouldHold: true)
        #expect(calls.count == 2)

        keeper.update(shouldHold: false)
        #expect(calls.suffix(2) == [["release", "--reason", "MacBridge"], ["off"]])
        #expect(!keeper.isHolding)
        keeper.update(shouldHold: false)
        #expect(calls.count == 4)
    }

    @Test func leavesLidAwakeOnIfYouHadTurnedItOnYourself() {
        var calls: [[String]] = []
        let keeper = LidClosedKeeper(run: { calls.append($0) }, sleepAlreadyDisabled: { true })
        keeper.update(shouldHold: true)
        keeper.update(shouldHold: false)
        #expect(calls == [["keepalive", "15m", "--reason", "MacBridge"], ["release", "--reason", "MacBridge"]])
    }

    @Test func doesNothingWithoutLidAwake() {
        let keeper = LidClosedKeeper(run: nil)
        #expect(!keeper.isAvailable)
        keeper.update(shouldHold: true)
        #expect(!keeper.isHolding)
    }

    @Test func theSettingSurvivesARestartAndOffIsTheDefault() {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls: [[String]] = []
        let model = BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory(), lidKeeper: LidClosedKeeper(run: { calls.append($0) }, sleepAlreadyDisabled: { false }))
        #expect(model.lidClosedMode == .off)
        model.allowsControl = true
        model.lidClosedMode = .always
        #expect(calls.isEmpty) // offline: nothing to stay reachable for
        let again = BridgeModel(identity: Identity(), defaults: defaults, secrets: .inMemory(), lidKeeper: LidClosedKeeper(run: { _ in }))
        #expect(again.lidClosedMode == .always)
    }
}
