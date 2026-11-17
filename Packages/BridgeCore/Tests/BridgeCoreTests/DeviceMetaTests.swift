import Foundation
import Testing
@testable import BridgeCore

@Suite struct ConnectInputTests {
    private func device(_ name: String, _ seed: UInt8) -> PairedDevice {
        let key = Data(repeating: seed, count: 32)
        return PairedDevice(id: DeviceID.derive(fromPublicKey: key), publicKey: key, name: name, thisMacMayControl: true)
    }

    @Test func recognisesNamesAddressesAndCodes() {
        let studio = device("Studio", 1), mini = device("Mac mini", 2), air = device("MacBook Air", 3)
        let all = [studio, mini, air]
        #expect(ConnectInput.parse("  ", devices: all) == .empty)
        #expect(ConnectInput.parse("studio", devices: all) == .device(studio))
        #expect(ConnectInput.parse("mini", devices: all) == .device(mini))          // only one match
        #expect(ConnectInput.parse("mac", devices: all) == .search)                 // two matches
        #expect(ConnectInput.parse(DeviceID.grouped(air.id).uppercased(), devices: all) == .device(air))
        #expect(ConnectInput.parse(String(mini.id.prefix(6)), devices: all) == .device(mini))
        #expect(ConnectInput.parse("nothing like it", devices: all) == .search)
        let code = PairingCode().display
        #expect(ConnectInput.parse(code.lowercased(), devices: all) == .pairingCode(code.lowercased()))
        #expect(ConnectInput.parse(code, devices: []) == .pairingCode(code))
    }

    @Test func aliasesAreSearchedToo() {
        let studio = device("Habibs-Mac-Studio", 1), mini = device("Mac mini", 2)
        let names = [studio.id: "Edit bay"]
        #expect(ConnectInput.parse("edit bay", devices: [studio, mini], names: names) == .device(studio))
        #expect(ConnectInput.filter([studio, mini], "bay", names: names) == [studio])
        #expect(ConnectInput.filter([studio, mini], "habibs", names: names) == [studio]) // own name still works
        #expect(ConnectInput.filter([studio, mini], "") == [studio, mini])
    }
}

@MainActor @Suite struct DeviceMetaStoreTests {
    private func defaults() -> UserDefaults {
        let suite = "macbridge-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func device(_ name: String, _ seed: UInt8) -> PairedDevice {
        let key = Data(repeating: seed, count: 32)
        return PairedDevice(id: DeviceID.derive(fromPublicKey: key), publicKey: key, name: name, thisMacMayControl: true)
    }

    @Test func aliasFavouriteAndAskFirstSurviveARestart() {
        let store = defaults()
        let studio = device("Studio", 1), mini = device("Mac mini", 2), air = device("Air", 3)
        store.set(try? JSONEncoder().encode([studio, mini, air]), forKey: "pairedDevices")
        let model = BridgeModel(identity: Identity(), defaults: store, secrets: .inMemory())
        #expect(model.controllableSorted.map(\.name) == ["Air", "Mac mini", "Studio"]) // by name when nothing else is known

        model.rename(mini, to: "  Server room  ")
        model.setFavourite(studio, true)
        model.setAsksFirst(air, true)
        #expect(model.displayName(mini) == "Server room")
        #expect(model.controllableSorted.first == studio)

        let again = BridgeModel(identity: Identity(), defaults: store, secrets: .inMemory())
        #expect(again.displayName(mini) == "Server room")
        #expect(again.meta[studio.id]?.isFavourite == true)
        #expect(again.meta[air.id]?.asksFirst == true)

        // Clearing everything leaves no entry behind.
        again.rename(mini, to: "")
        #expect(again.displayName(mini) == "Mac mini")
        #expect(again.meta[mini.id] == nil)
    }
}
