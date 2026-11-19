import Foundation
import Testing
@testable import BridgeCore

@Suite struct PairingLinkTests {
    private let code = PairingCode().display

    @Test func roundTripsCodeAndServer() throws {
        let link = PairingLink(code: code, server: "ws://100.77.252.76:8787")
        let text = try #require(link.url?.absoluteString)
        #expect(text.hasPrefix("macbridge://pair?"))
        #expect(PairingLink(text) == link)
    }

    @Test func readsABareCode() {
        #expect(PairingLink(code) == PairingLink(code: code, server: nil))
        #expect(PairingLink("  \(code.lowercased()) ")?.code != nil)
    }

    @Test func leavesOutAnEmptyServer() throws {
        let text = try #require(PairingLink(code: code, server: "").url?.absoluteString)
        #expect(!text.contains("server"))
        #expect(PairingLink(text)?.server == nil)
    }

    @Test func dropsAServerThatIsNotAWebSocket() throws {
        let text = try #require(PairingLink(code: code, server: "https://evil.example").url?.absoluteString)
        #expect(PairingLink(text) == PairingLink(code: code, server: nil))
    }

    @Test func rejectsOtherCodes() {
        #expect(PairingLink("https://example.com") == nil)
        #expect(PairingLink("macbridge://pair?code=nope") == nil)
        #expect(PairingLink("macbridge://other?code=\(code)") == nil)
        #expect(PairingLink("hello") == nil)
    }
}
