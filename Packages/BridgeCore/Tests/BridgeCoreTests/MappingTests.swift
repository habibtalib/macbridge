import AppKit
import Foundation
import Testing
@testable import BridgeCore

@Suite struct InputMappingTests {
    @Test func flipsYAndNormalises() {
        let size = CGSize(width: 200, height: 100)
        // AppKit's origin is bottom-left; the wire format's is top-left.
        #expect(InputMapping.normalized(CGPoint(x: 0, y: 100), in: size) == (0, 0))
        #expect(InputMapping.normalized(CGPoint(x: 200, y: 0), in: size) == (1, 1))
        #expect(InputMapping.normalized(CGPoint(x: 50, y: 75), in: size) == (0.25, 0.25))
    }

    @Test func clampsPointsOutsideTheView() {
        let size = CGSize(width: 200, height: 100)
        #expect(InputMapping.normalized(CGPoint(x: -30, y: 400), in: size) == (0, 0))
        #expect(InputMapping.normalized(CGPoint(x: 900, y: -5), in: size) == (1, 1))
        #expect(InputMapping.normalized(CGPoint(x: 10, y: 10), in: .zero) == (0, 0))
    }

    @Test func wireModifiersMatchCoreGraphicsFlags() {
        #expect(InputMapping.wireModifiers([.command]) == UInt32(CGEventFlags.maskCommand.rawValue))
        #expect(InputMapping.wireModifiers([.shift, .option])
            == UInt32(CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue))
        #expect(InputMapping.wireModifiers([.control]) == UInt32(CGEventFlags.maskControl.rawValue))
        #expect(InputMapping.wireModifiers([.capsLock]) == UInt32(CGEventFlags.maskAlphaShift.rawValue))
        #expect(InputMapping.wireModifiers([.function]) == UInt32(CGEventFlags.maskSecondaryFn.rawValue))
        // Bits that are not modifiers (numeric pad, device-dependent) are dropped.
        #expect(InputMapping.wireModifiers([.numericPad]) == 0)
    }

    @Test func modifierKeyStateFollowsItsFlag() {
        #expect(InputMapping.modifierIsDown(keyCode: 55, flags: [.command]) == true)
        #expect(InputMapping.modifierIsDown(keyCode: 55, flags: []) == false)
        #expect(InputMapping.modifierIsDown(keyCode: 60, flags: [.shift]) == true)
        #expect(InputMapping.modifierIsDown(keyCode: 58, flags: [.command]) == false)
        #expect(InputMapping.modifierIsDown(keyCode: 0, flags: [.command]) == nil)
    }
}

@Suite struct CaptureSizeTests {
    @Test func keepsSmallDisplaysAsTheyAre() {
        #expect(ScreenCapturer.fit(CGSize(width: 1920, height: 1080), maxWidth: 2560, maxHeight: 1600) == (1920, 1080))
    }

    @Test func scalesDownKeepingAspectRatio() {
        let (w, h) = ScreenCapturer.fit(CGSize(width: 5120, height: 2880), maxWidth: 2560, maxHeight: 1600)
        #expect(w == 2560 && h == 1440)
    }

    @Test func limitsByHeightForTallDisplays() {
        let (w, h) = ScreenCapturer.fit(CGSize(width: 3024, height: 1964), maxWidth: 2560, maxHeight: 1600)
        #expect(h == 1600 && w == 2462)
        #expect(w % 2 == 0)
    }

    @Test func producesEvenDimensions() {
        let (w, h) = ScreenCapturer.fit(CGSize(width: 1365, height: 767), maxWidth: 2560, maxHeight: 1600)
        #expect(w == 1364 && h == 766)
        #expect(ScreenCapturer.fit(.zero, maxWidth: 10, maxHeight: 10) == (2, 2))
    }
}

@Suite struct SettingsValidationTests {
    @Test(arguments: ["studio", "Habibs-MacBook-Pro", "a", "mac_2", String(repeating: "x", count: 64)])
    func acceptsDeviceName(_ name: String) {
        #expect(BridgeModel.isValidDeviceName(name))
    }

    @Test(arguments: ["", "has space", "ünï", "a/b", "../x", String(repeating: "x", count: 65)])
    func rejectsDeviceName(_ name: String) {
        #expect(!BridgeModel.isValidDeviceName(name))
    }

    @Test func defaultDeviceNameIsAlwaysValid() {
        for host in ["Habib’s MacBook Pro", "Studio (2)", "  ", "émile", nil, String(repeating: "long name ", count: 20)] {
            let name = BridgeModel.defaultDeviceName(from: host)
            #expect(BridgeModel.isValidDeviceName(name), "\(host ?? "nil") → \(name)")
        }
        #expect(BridgeModel.defaultDeviceName(from: "Habib’s MacBook Pro") == "Habib-s-MacBook-Pro")
        #expect(BridgeModel.defaultDeviceName(from: nil) == "mac")
    }

    @Test func serverURLMustBeWebSocket() {
        #expect(BridgeModel.parseServerURL("wss://bridge.example.com") != nil)
        #expect(BridgeModel.parseServerURL(" ws://192.168.1.5:8787 ") != nil)
        #expect(BridgeModel.parseServerURL("https://bridge.example.com") == nil)
        #expect(BridgeModel.parseServerURL("bridge.example.com") == nil)
        #expect(BridgeModel.parseServerURL("wss://") == nil)
        #expect(BridgeModel.parseServerURL("") == nil)
    }
}

@Suite struct SignalPayloadTests {
    @Test(arguments: [
        SignalPayload.request,
        .offer(sdp: "v=0\r\n"),
        .answer(sdp: "v=0\r\n"),
        .candidate(sdp: "candidate:1 1 udp 1 10.0.0.1 5000 typ host", mLineIndex: 0, mid: "0"),
        .candidate(sdp: "candidate:2", mLineIndex: 1, mid: nil),
        .bye,
    ])
    func roundTripsThroughJSON(_ payload: SignalPayload) throws {
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(SignalPayload.self, from: data) == payload)
    }

    @Test func usesTheWireFieldNamesTheServerRelays() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SignalPayload.offer(sdp: "x"))) as? [String: String]
        #expect(json == ["kind": "offer", "sdp": "x"])
    }

    @Test func rejectsUnknownKinds() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SignalPayload.self, from: Data(#"{"kind":"takeover"}"#.utf8))
        }
    }
}
