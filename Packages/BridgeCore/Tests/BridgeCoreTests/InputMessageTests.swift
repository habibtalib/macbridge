import Foundation
import Testing
@testable import BridgeCore

@Suite struct InputMessageTests {
    @Test(arguments: [
        InputMessage.mouseMove(x: 0.25, y: 0.75),
        .mouseButton(button: .right, isDown: true, x: 0.5, y: 0.125, clickCount: 2),
        .scroll(dx: -3.5, dy: 120),
        .key(keyCode: 0x24, isDown: true, modifiers: 0x0010_0000),
        .key(keyCode: 0xFFFF, isDown: false, modifiers: .max),
        .clipboard(text: "héllo 👋\nline two"),
        .clipboard(text: ""),
        .nextDisplay,
        .quality(.sharp),
        .quality(.light),
    ])
    func roundTrips(_ message: InputMessage) throws {
        #expect(try InputMessage(decoding: message.encoded()) == message)
    }

    @Test func mouseMoveIsTenBytes() {
        #expect(InputMessage.mouseMove(x: 0, y: 1).encoded().count == 10)
    }

    @Test func movesAndScrollsUseTheUnreliableChannel() {
        #expect(InputMessage.mouseMove(x: 0, y: 0).prefersUnreliableChannel)
        #expect(InputMessage.scroll(dx: 0, dy: 1).prefersUnreliableChannel)
        #expect(!InputMessage.key(keyCode: 0, isDown: true, modifiers: 0).prefersUnreliableChannel)
        #expect(!InputMessage.mouseButton(button: .left, isDown: true, x: 0, y: 0, clickCount: 1).prefersUnreliableChannel)
        #expect(!InputMessage.clipboard(text: "x").prefersUnreliableChannel)
    }

    @Test func clampsOutOfRangeCoordinates() throws {
        let decoded = try InputMessage(decoding: InputMessage.mouseMove(x: -4, y: 9).encoded())
        #expect(decoded == .mouseMove(x: 0, y: 1))
    }

    @Test func rejectsNonFiniteValues() {
        #expect(throws: InputMessageError.invalidCoordinate) {
            try InputMessage(decoding: InputMessage.mouseMove(x: .nan, y: 0).encoded())
        }
        #expect(throws: InputMessageError.invalidCoordinate) {
            try InputMessage(decoding: InputMessage.scroll(dx: .infinity, dy: 0).encoded())
        }
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: InputMessageError.tooShort) {
            try InputMessage(decoding: Data())
        }
        #expect(throws: InputMessageError.unsupportedVersion(9)) {
            try InputMessage(decoding: Data([9, 1]))
        }
        #expect(throws: InputMessageError.unknownType(200)) {
            try InputMessage(decoding: Data([1, 200]))
        }
        #expect(throws: InputMessageError.tooShort) {
            try InputMessage(decoding: InputMessage.mouseMove(x: 0, y: 0).encoded().dropLast(1))
        }
        #expect(throws: InputMessageError.unknownButton(7)) {
            try InputMessage(decoding: Data([1, 2, 7, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        }
        #expect(throws: InputMessageError.unknownQuality(9)) {
            try InputMessage(decoding: Data([1, 7, 9]))
        }
        #expect(throws: InputMessageError.tooShort) {
            try InputMessage(decoding: Data([1, 7]))
        }
        #expect(throws: InputMessageError.invalidText) {
            try InputMessage(decoding: Data([1, 5, 0xFF, 0xFE]))
        }
    }
}
