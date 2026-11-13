import XCTest
@testable import SidePanelCore

final class KeyEncoderTests: XCTestCase {
    private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    func testCursorKeys() {
        XCTAssertEqual(s(KeyEncoder.encode(.up)), "\u{1B}[A")
        XCTAssertEqual(s(KeyEncoder.encode(.up, applicationCursor: true)), "\u{1B}OA")
        XCTAssertEqual(s(KeyEncoder.encode(.left, modifiers: [.option])), "\u{1B}[1;3D")
        XCTAssertEqual(s(KeyEncoder.encode(.right, modifiers: [.control, .shift])), "\u{1B}[1;6C")
    }

    func testEditingKeys() {
        XCTAssertEqual(KeyEncoder.encode(.backspace), [0x7F])
        XCTAssertEqual(KeyEncoder.encode(.backspace, modifiers: .option), [0x1B, 0x7F])
        XCTAssertEqual(s(KeyEncoder.encode(.forwardDelete)), "\u{1B}[3~")
        XCTAssertEqual(s(KeyEncoder.encode(.pageUp, modifiers: .shift)), "\u{1B}[5;2~")
        XCTAssertEqual(s(KeyEncoder.encode(.tab, modifiers: .shift)), "\u{1B}[Z")
        XCTAssertEqual(KeyEncoder.encode(.enter), [0x0D])
    }

    func testFunctionKeys() {
        XCTAssertEqual(s(KeyEncoder.encode(.function(1))), "\u{1B}OP")
        XCTAssertEqual(s(KeyEncoder.encode(.function(5))), "\u{1B}[15~")
        XCTAssertEqual(s(KeyEncoder.encode(.function(12))), "\u{1B}[24~")
        XCTAssertEqual(s(KeyEncoder.encode(.function(2), modifiers: .shift)), "\u{1B}[1;2Q")
    }

    func testControlCharacters() {
        XCTAssertEqual(KeyEncoder.controlCharacter(for: "c"), 3)
        XCTAssertEqual(KeyEncoder.controlCharacter(for: "C"), 3)
        XCTAssertEqual(KeyEncoder.controlCharacter(for: " "), 0)
        XCTAssertEqual(KeyEncoder.controlCharacter(for: "["), 0x1B)
        XCTAssertNil(KeyEncoder.controlCharacter(for: "é"))
    }

    func testBracketedPaste() {
        XCTAssertEqual(s(KeyEncoder.paste("a\nb", bracketed: false)), "a\rb")
        XCTAssertEqual(s(KeyEncoder.paste("x\u{1B}[201~y", bracketed: true)), "\u{1B}[200~xy\u{1B}[201~")
    }

    func testMouseEncoding() {
        XCTAssertEqual(s(KeyEncoder.mouse(.wheelUp, column: 4, row: 9, pressed: true, sgr: true)), "\u{1B}[<64;5;10M")
        XCTAssertEqual(KeyEncoder.mouse(.left, column: 0, row: 0, pressed: true, sgr: false), [0x1B, 0x5B, 0x4D, 32, 33, 33])
    }
}
