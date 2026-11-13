import XCTest
@testable import SidePanelCore

final class TerminalEmulatorTests: XCTestCase {

    private func make(_ cols: Int = 20, _ rows: Int = 5) -> TerminalEmulator {
        TerminalEmulator(columns: cols, rows: rows, scrollbackLimit: 100)
    }

    func testPrintsTextAndMovesCursor() {
        let t = make()
        t.feed("hello")
        XCTAssertEqual(t.line(at: t.scrollback.count).text, "hello")
        XCTAssertEqual(t.cursor, CursorPosition(column: 5, row: 0))
    }

    func testCarriageReturnLineFeed() {
        let t = make()
        t.feed("ab\r\ncd")
        XCTAssertEqual(t.screen[0].text, "ab")
        XCTAssertEqual(t.screen[1].text, "cd")
        XCTAssertEqual(t.cursor, CursorPosition(column: 2, row: 1))
    }

    func testAutoWrapMarksLineAsWrapped() {
        let t = make(5, 3)
        t.feed("abcdefg")
        XCTAssertEqual(t.screen[0].text, "abcde")
        XCTAssertTrue(t.screen[0].wrapped)
        XCTAssertEqual(t.screen[1].text, "fg")
        XCTAssertEqual(t.text(from: (0, 0), to: (1, 5)), "abcdefg")
    }

    func testPendingWrapDoesNotWrapUntilNextCharacter() {
        let t = make(5, 3)
        t.feed("abcde")
        XCTAssertEqual(t.cursor, CursorPosition(column: 4, row: 0))
        t.feed("\r")
        XCTAssertEqual(t.cursor, CursorPosition(column: 0, row: 0))
    }

    func testScrollingPushesIntoScrollback() {
        let t = make(10, 3)
        t.feed("1\r\n2\r\n3\r\n4\r\n5")
        XCTAssertEqual(t.scrollback.map(\.text), ["1", "2"])
        XCTAssertEqual(t.screen.map(\.text), ["3", "4", "5"])
        XCTAssertEqual(t.totalLineCount, 5)
    }

    func testCursorPositioningAndErase() {
        let t = make(10, 3)
        t.feed("xxxxxxxxxx\r\nyyyyyyyyyy")
        t.feed("\u{1B}[1;4H")           // row 1, col 4
        t.feed("\u{1B}[K")              // erase to end of line
        XCTAssertEqual(t.screen[0].text, "xxx")
        t.feed("\u{1B}[2J")
        XCTAssertEqual(t.screenText.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testSGRColorsAndFlags() {
        let t = make()
        t.feed("\u{1B}[1;31mR\u{1B}[0m\u{1B}[38;5;200mP\u{1B}[48;2;1;2;3mQ\u{1B}[38:2::9:8:7mZ")
        let cells = t.screen[0].cells
        XCTAssertEqual(cells[0].attributes.foreground, .indexed(1))
        XCTAssertTrue(cells[0].attributes.flags.contains(.bold))
        XCTAssertEqual(cells[1].attributes, CellAttributes(foreground: .indexed(200)))
        XCTAssertEqual(cells[2].attributes.background, .rgb(1, 2, 3))
        XCTAssertEqual(cells[3].attributes.foreground, .rgb(9, 8, 7))
    }

    func testBrightColors() {
        let t = make()
        t.feed("\u{1B}[92;103mx")
        XCTAssertEqual(t.screen[0].cells[0].attributes.foreground, .indexed(10))
        XCTAssertEqual(t.screen[0].cells[0].attributes.background, .indexed(11))
    }

    func testAlternateScreenPreservesMainScreen() {
        let t = make(10, 3)
        t.feed("main")
        t.feed("\u{1B}[?1049h")
        XCTAssertTrue(t.isAlternateScreen)
        XCTAssertEqual(t.screen[0].text, "")
        t.feed("alt")
        t.feed("\u{1B}[?1049l")
        XCTAssertFalse(t.isAlternateScreen)
        XCTAssertEqual(t.screen[0].text, "main")
        XCTAssertEqual(t.cursor.column, 4)
    }

    func testScrollRegion() {
        let t = make(10, 5)
        t.feed("a\r\nb\r\nc\r\nd\r\ne")
        t.feed("\u{1B}[2;4r")      // region rows 2..4
        t.feed("\u{1B}[4;1H\n")    // LF at bottom margin scrolls the region only
        XCTAssertEqual(t.screen.map(\.text), ["a", "c", "d", "", "e"])
        XCTAssertTrue(t.scrollback.isEmpty)
    }

    func testInsertAndDeleteCharacters() {
        let t = make(10, 2)
        t.feed("abcdef\u{1B}[1;3H\u{1B}[2@")
        XCTAssertEqual(t.screen[0].text, "ab  cdef")
        t.feed("\u{1B}[3P")
        XCTAssertEqual(t.screen[0].text, "abdef")
    }

    func testInsertAndDeleteLines() {
        let t = make(5, 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.feed("\u{1B}[2;1H\u{1B}[L")
        XCTAssertEqual(t.screen.map(\.text), ["1", "", "2", "3"])
        t.feed("\u{1B}[2M")
        XCTAssertEqual(t.screen.map(\.text), ["1", "3", "", ""])
    }

    func testWideCharactersOccupyTwoCells() {
        let t = make(10, 2)
        t.feed("a漢b")
        let cells = t.screen[0].cells
        XCTAssertEqual(cells[1].character, "漢")
        XCTAssertEqual(cells[1].width, 2)
        XCTAssertEqual(cells[2].width, 0)
        XCTAssertEqual(cells[3].character, "b")
        XCTAssertEqual(t.screen[0].text, "a漢b")
    }

    func testCombiningCharactersAttachToPreviousCell() {
        let t = make(10, 2)
        t.feed("e\u{0301}x")
        XCTAssertEqual(t.screen[0].cells[0].character, "é")
        XCTAssertEqual(t.screen[0].cells[1].character, "x")
    }

    func testUTF8SplitAcrossFeeds() {
        let t = make(10, 2)
        let bytes = Array("ü".utf8)
        t.feed([bytes[0]])
        t.feed([bytes[1]])
        XCTAssertEqual(t.screen[0].text, "ü")
    }

    func testDeviceStatusReport() {
        let t = make(10, 5)
        var replies: [String] = []
        t.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        t.feed("\u{1B}[3;7H\u{1B}[6n\u{1B}[c")
        XCTAssertEqual(replies, ["\u{1B}[3;7R", "\u{1B}[?62;22c"])
    }

    func testOSCTitleWithBELAndST() {
        let t = make()
        var titles: [String] = []
        t.onTitleChange = { titles.append($0) }
        t.feed("\u{1B}]0;first\u{07}\u{1B}]2;second\u{1B}\\after")
        XCTAssertEqual(titles, ["first", "second"])
        XCTAssertEqual(t.title, "second")
        XCTAssertEqual(t.screen[0].text, "after")
    }

    func testOSC7WorkingDirectory() {
        let t = make()
        t.feed("\u{1B}]7;file://host/Users/me/Projects\u{07}")
        XCTAssertEqual(t.currentDirectory, "/Users/me/Projects")
    }

    func testDECLineDrawingCharset() {
        let t = make()
        t.feed("\u{1B}(0lqk\u{1B}(Bx")
        XCTAssertEqual(t.screen[0].text, "┌─┐x")
    }

    func testModesAreTracked() {
        let t = make()
        t.feed("\u{1B}[?1h\u{1B}[?2004h\u{1B}[?25l\u{1B}[6 q")
        XCTAssertTrue(t.applicationCursorKeys)
        XCTAssertTrue(t.bracketedPaste)
        XCTAssertFalse(t.cursorVisible)
        XCTAssertEqual(t.cursorShape, .bar)
        t.feed("\u{1B}c")
        XCTAssertFalse(t.applicationCursorKeys)
        XCTAssertTrue(t.cursorVisible)
    }

    func testTabStops() {
        let t = make(20, 2)
        t.feed("a\tb")
        XCTAssertEqual(t.cursor.column, 9)
        XCTAssertEqual(t.screen[0].cells[8].character, "b")
    }

    func testResizeShrinkMovesLinesToScrollbackAndGrowRestoresThem() {
        let t = make(10, 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.resize(columns: 10, rows: 2)
        XCTAssertEqual(t.screen.map(\.text), ["3", "4"])
        XCTAssertEqual(t.scrollback.map(\.text), ["1", "2"])
        XCTAssertEqual(t.cursor.row, 1)
        t.resize(columns: 10, rows: 4)
        XCTAssertEqual(t.screen.map(\.text), ["1", "2", "3", "4"])
        XCTAssertEqual(t.cursor.row, 3)
    }

    func testResizeWidthTruncatesAndPads() {
        let t = make(10, 2)
        t.feed("abcdefghij")
        t.resize(columns: 4, rows: 2)
        XCTAssertEqual(t.screen[0].cells.count, 4)
        t.resize(columns: 12, rows: 2)
        XCTAssertEqual(t.screen[0].cells.count, 12)
        XCTAssertEqual(t.cursor.column, 3)
    }

    func testScrollbackLimit() {
        let t = TerminalEmulator(columns: 10, rows: 2, scrollbackLimit: 10)
        for i in 0..<200 { t.feed("\(i)\r\n") }
        XCTAssertLessThanOrEqual(t.scrollback.count, 10 + 64)
        XCTAssertGreaterThan(t.discardedLineCount, 0)
        XCTAssertEqual(t.scrollback.count + t.discardedLineCount, 199)
    }

    func testEscapeAbortsPartialCSI() {
        let t = make()
        t.feed("\u{1B}[12\u{1B}[31mX")
        XCTAssertEqual(t.screen[0].cells[0].attributes.foreground, .indexed(1))
        XCTAssertEqual(t.screen[0].text, "X")
    }

    func testRepeatPrecedingCharacter() {
        let t = make()
        t.feed("-\u{1B}[4b")
        XCTAssertEqual(t.screen[0].text, "-----")
    }
}
