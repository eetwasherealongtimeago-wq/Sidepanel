import Foundation

/// An xterm-compatible terminal state machine.
///
/// Bytes produced by the PTY go in through `feed(_:)`; the resulting screen,
/// scrollback, cursor and modes are exposed for a renderer. Replies the
/// terminal must send back to the application (device attributes, cursor
/// position reports) are delivered through `onResponse`.
///
/// The emulator is not thread-safe: feed it and read it from one thread.
public final class TerminalEmulator {

    // MARK: Public state

    public private(set) var columns: Int
    public private(set) var rows: Int

    /// Lines that have scrolled off the top of the main screen, oldest first.
    public private(set) var scrollback: [TerminalLine] = []
    public var scrollbackLimit: Int {
        didSet { trimScrollback() }
    }
    /// Total number of lines ever discarded from the head of `scrollback`.
    /// Lets a renderer keep absolute line references (e.g. a selection) stable.
    public private(set) var discardedLineCount: Int = 0

    /// The visible grid (`rows` lines).
    public private(set) var screen: [TerminalLine]
    public private(set) var cursor = CursorPosition(column: 0, row: 0)
    public private(set) var cursorVisible = true
    public private(set) var cursorShape: CursorShape = .block
    public private(set) var cursorBlinks = true

    public private(set) var isAlternateScreen = false
    public private(set) var applicationCursorKeys = false
    public private(set) var applicationKeypad = false
    public private(set) var bracketedPaste = false
    public private(set) var focusReporting = false
    public private(set) var mouseTracking: MouseTrackingMode = .none
    public private(set) var sgrMouse = false
    public private(set) var reverseVideo = false

    public private(set) var title: String = ""
    /// Working directory announced by the shell via OSC 7, if any.
    public private(set) var currentDirectory: String?

    /// Incremented on every state change; renderers can compare it cheaply.
    public private(set) var version: UInt64 = 0

    public var onResponse: (([UInt8]) -> Void)?
    public var onBell: (() -> Void)?
    public var onTitleChange: ((String) -> Void)?

    // MARK: Private state

    private struct SavedCursor {
        var position = CursorPosition(column: 0, row: 0)
        var attributes = CellAttributes.plain
        var pendingWrap = false
        var originMode = false
        var charsets: [Charset] = [.ascii, .ascii]
        var activeCharset = 0
    }

    private enum Charset { case ascii, decGraphics }

    private enum ParserState {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case osc
        case oscEscape
        case passthrough        // DCS / SOS / PM / APC: consumed and ignored
        case passthroughEscape
        case charset(Int)       // designating G0..G3
    }

    private var attributes = CellAttributes.plain
    private var pendingWrap = false
    private var originMode = false
    private var autoWrap = true
    private var insertMode = false
    private var newLineMode = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabStops: [Bool]
    private var charsets: [Charset] = [.ascii, .ascii, .ascii, .ascii]
    private var activeCharset = 0

    private var savedCursorMain = SavedCursor()
    private var savedCursorAlt = SavedCursor()
    private var mainScreenWhileAlt: [TerminalLine]?

    private var state: ParserState = .ground
    private var params: [[Int]] = []
    private var currentParam: Int? = nil
    private var currentGroup: [Int] = []
    private var privateMarker: UInt8 = 0
    private var intermediates: [UInt8] = []
    private var oscBuffer: [UInt8] = []
    private var lastPrinted: Unicode.Scalar?

    private var utf8Buffer: [UInt8] = []
    private var utf8Expected = 0

    // MARK: Init

    public init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 10_000) {
        let c = max(columns, 2)
        let r = max(rows, 2)
        self.columns = c
        self.rows = r
        self.scrollbackLimit = scrollbackLimit
        self.scrollBottom = r - 1
        self.screen = Array(repeating: TerminalLine(columns: c), count: r)
        self.tabStops = TerminalEmulator.defaultTabStops(c)
    }

    private static func defaultTabStops(_ columns: Int) -> [Bool] {
        (0..<columns).map { $0 > 0 && $0 % 8 == 0 }
    }

    // MARK: Reading

    /// Number of addressable lines: scrollback followed by the screen.
    public var totalLineCount: Int { scrollback.count + rows }

    /// A line by index into `scrollback + screen`.
    public func line(at index: Int) -> TerminalLine {
        if index < scrollback.count { return scrollback[max(index, 0)] }
        let r = index - scrollback.count
        return screen[min(max(r, 0), rows - 1)]
    }

    /// The text between two (line index, column) positions, inclusive of the
    /// start and exclusive of the end column. Soft-wrapped lines are joined.
    public func text(from start: (line: Int, column: Int), to end: (line: Int, column: Int)) -> String {
        var a = start, b = end
        if (b.line, b.column) < (a.line, a.column) { swap(&a, &b) }
        let lastLine = totalLineCount - 1
        guard a.line <= lastLine else { return "" }
        var out = ""
        var lineIndex = max(a.line, 0)
        while lineIndex <= min(b.line, lastLine) {
            let ln = line(at: lineIndex)
            let from = lineIndex == a.line ? a.column : 0
            let to = lineIndex == b.line ? b.column : ln.cells.count
            var piece = ""
            if from < to {
                for i in max(from, 0)..<min(to, ln.cells.count) where ln.cells[i].width != 0 {
                    piece.append(ln.cells[i].character)
                }
            }
            let continues = ln.wrapped && lineIndex != b.line
            if !continues {
                while piece.last == " " { piece.removeLast() }
            }
            out += piece
            if lineIndex != b.line && !continues { out += "\n" }
            lineIndex += 1
        }
        return out
    }

    /// Plain text of the whole screen (useful for tests and accessibility).
    public var screenText: String {
        screen.map(\.text).joined(separator: "\n")
    }

    // MARK: Feeding

    public func feed(_ string: String) {
        feed(Array(string.utf8))
    }

    public func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes { process(byte) }
        version &+= 1
    }

    private func process(_ byte: UInt8) {
        // C0 controls are executed in (almost) every state.
        switch state {
        case .osc, .oscEscape, .passthrough, .passthroughEscape:
            break
        default:
            if byte < 0x20 && byte != 0x1B {
                if utf8Expected > 0 { flushInvalidUTF8() }
                executeControl(byte)
                return
            }
            if byte == 0x1B {
                // ESC always (re)starts an escape sequence, aborting any partial one.
                if utf8Expected > 0 { flushInvalidUTF8() }
                state = .escape
                intermediates.removeAll(keepingCapacity: true)
                return
            }
        }

        switch state {
        case .ground:
            decodeUTF8(byte)

        case .escape:
            escapeDispatch(byte)

        case .escapeIntermediate:
            if byte >= 0x20 && byte <= 0x2F {
                intermediates.append(byte)
            } else {
                if intermediates.first == UInt8(ascii: "#") && byte == UInt8(ascii: "8") {
                    screenAlignment()
                }
                state = .ground
            }

        case .charset(let g):
            charsets[g] = (byte == UInt8(ascii: "0")) ? .decGraphics : .ascii
            state = .ground

        case .csi:
            csiCollect(byte)

        case .osc:
            if byte == 0x07 {
                oscDispatch()
                state = .ground
            } else if byte == 0x1B {
                state = .oscEscape
            } else if oscBuffer.count < 8192 {
                oscBuffer.append(byte)
            }

        case .oscEscape:
            if byte == UInt8(ascii: "\\") {
                oscDispatch()
                state = .ground
            } else {
                // Not a string terminator: abandon the OSC and reinterpret.
                oscBuffer.removeAll()
                state = .escape
                escapeDispatch(byte)
            }

        case .passthrough:
            if byte == 0x1B { state = .passthroughEscape }
            else if byte == 0x07 { state = .ground }

        case .passthroughEscape:
            state = byte == UInt8(ascii: "\\") ? .ground : .passthrough
        }
    }

    // MARK: UTF-8

    private func decodeUTF8(_ byte: UInt8) {
        if utf8Expected == 0 {
            switch byte {
            case 0x20..<0x7F:
                printScalar(Unicode.Scalar(byte))
            case 0x7F:
                break // DEL is ignored on output
            case 0xC2...0xDF:
                utf8Buffer = [byte]; utf8Expected = 1
            case 0xE0...0xEF:
                utf8Buffer = [byte]; utf8Expected = 2
            case 0xF0...0xF4:
                utf8Buffer = [byte]; utf8Expected = 3
            default:
                printScalar("\u{FFFD}")
            }
            return
        }
        guard byte & 0xC0 == 0x80 else {
            flushInvalidUTF8()
            decodeUTF8(byte)
            return
        }
        utf8Buffer.append(byte)
        utf8Expected -= 1
        if utf8Expected == 0 {
            if let s = String(bytes: utf8Buffer, encoding: .utf8), let scalar = s.unicodeScalars.first {
                printScalar(scalar)
            } else {
                printScalar("\u{FFFD}")
            }
            utf8Buffer.removeAll(keepingCapacity: true)
        }
    }

    private func flushInvalidUTF8() {
        utf8Buffer.removeAll(keepingCapacity: true)
        utf8Expected = 0
        printScalar("\u{FFFD}")
    }

    // MARK: Printing

    private static let decGraphicsMap: [UInt8: Unicode.Scalar] = [
        0x5F: " ", 0x60: "◆", 0x61: "▒", 0x62: "␉", 0x63: "␌", 0x64: "␍", 0x65: "␊",
        0x66: "°", 0x67: "±", 0x68: "␤", 0x69: "␋", 0x6A: "┘", 0x6B: "┐", 0x6C: "┌",
        0x6D: "└", 0x6E: "┼", 0x6F: "⎺", 0x70: "⎻", 0x71: "─", 0x72: "⎼", 0x73: "⎽",
        0x74: "├", 0x75: "┤", 0x76: "┴", 0x77: "┬", 0x78: "│", 0x79: "≤", 0x7A: "≥",
        0x7B: "π", 0x7C: "≠", 0x7D: "£", 0x7E: "·",
    ]

    private func printScalar(_ input: Unicode.Scalar) {
        var scalar = input
        if charsets[activeCharset] == .decGraphics, input.value < 0x80,
           let mapped = TerminalEmulator.decGraphicsMap[UInt8(input.value)] {
            scalar = mapped
        }

        let width = CharacterWidth.of(scalar)
        if width == 0 {
            attachCombining(scalar)
            return
        }
        lastPrinted = scalar

        if pendingWrap {
            if autoWrap {
                screen[cursor.row].wrapped = true
                cursor.column = 0
                index()
            }
            pendingWrap = false
        }

        if width == 2 && cursor.column == columns - 1 {
            guard autoWrap else { return }
            screen[cursor.row].cells[cursor.column] = Cell.erased(with: attributes)
            screen[cursor.row].wrapped = true
            cursor.column = 0
            index()
        }

        if insertMode {
            insertBlankCells(width)
        }

        let row = cursor.row
        let col = cursor.column
        clearWideCharacterFragments(row: row, column: col, width: width)
        screen[row].cells[col] = Cell(character: Character(scalar), width: UInt8(width), attributes: attributes)
        if width == 2 && col + 1 < columns {
            screen[row].cells[col + 1] = Cell(character: " ", width: 0, attributes: attributes)
        }

        let next = col + width
        if next >= columns {
            cursor.column = columns - 1
            pendingWrap = true
        } else {
            cursor.column = next
        }
    }

    /// Keeps wide characters consistent when one half is overwritten.
    private func clearWideCharacterFragments(row: Int, column: Int, width: Int) {
        if screen[row].cells[column].width == 0 && column > 0 {
            screen[row].cells[column - 1] = Cell.erased(with: screen[row].cells[column - 1].attributes)
        }
        let lastTouched = column + width - 1
        if lastTouched < columns && screen[row].cells[lastTouched].width == 2 && lastTouched + 1 < columns {
            screen[row].cells[lastTouched + 1] = Cell.erased(with: screen[row].cells[lastTouched + 1].attributes)
        }
    }

    private func attachCombining(_ scalar: Unicode.Scalar) {
        var col = pendingWrap ? cursor.column : cursor.column - 1
        guard col >= 0 else { return }
        if screen[cursor.row].cells[col].width == 0 && col > 0 { col -= 1 }
        let combined = String(screen[cursor.row].cells[col].character) + String(scalar)
        if combined.count == 1, let ch = combined.first {
            screen[cursor.row].cells[col].character = ch
        }
    }

    // MARK: C0 controls

    private func executeControl(_ byte: UInt8) {
        switch byte {
        case 0x07: onBell?()
        case 0x08: // BS
            if pendingWrap { pendingWrap = false }
            else if cursor.column > 0 { cursor.column -= 1 }
        case 0x09: tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if newLineMode { cursor.column = 0 }
        case 0x0D:
            cursor.column = 0
            pendingWrap = false
        case 0x0E: activeCharset = 1 // SO
        case 0x0F: activeCharset = 0 // SI
        case 0x18, 0x1A: state = .ground // CAN / SUB
        default: break
        }
    }

    // MARK: ESC

    private func escapeDispatch(_ byte: UInt8) {
        state = .ground
        switch byte {
        case UInt8(ascii: "["):
            beginCSI()
        case UInt8(ascii: "]"):
            oscBuffer.removeAll(keepingCapacity: true)
            state = .osc
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            state = .passthrough
        case UInt8(ascii: "("): state = .charset(0)
        case UInt8(ascii: ")"): state = .charset(1)
        case UInt8(ascii: "*"): state = .charset(2)
        case UInt8(ascii: "+"): state = .charset(3)
        case 0x20...0x27, 0x2C...0x2F:
            intermediates = [byte]
            state = .escapeIntermediate
        case UInt8(ascii: "7"): saveCursor()
        case UInt8(ascii: "8"): restoreCursor()
        case UInt8(ascii: "D"): index()
        case UInt8(ascii: "E"):
            cursor.column = 0
            index()
        case UInt8(ascii: "H"):
            tabStops[cursor.column] = true
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "c"): fullReset()
        case UInt8(ascii: "="): applicationKeypad = true
        case UInt8(ascii: ">"): applicationKeypad = false
        case UInt8(ascii: "\\"): break // stray ST
        default: break
        }
    }

    // MARK: CSI

    private func beginCSI() {
        params.removeAll(keepingCapacity: true)
        currentGroup.removeAll(keepingCapacity: true)
        currentParam = nil
        privateMarker = 0
        intermediates.removeAll(keepingCapacity: true)
        state = .csi
    }

    private func csiCollect(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let digit = Int(byte - UInt8(ascii: "0"))
            let value = (currentParam ?? 0) * 10 + digit
            currentParam = min(value, 65_535)
        case UInt8(ascii: ":"):
            currentGroup.append(currentParam ?? -1)
            currentParam = nil
        case UInt8(ascii: ";"):
            currentGroup.append(currentParam ?? -1)
            params.append(currentGroup)
            currentGroup = []
            currentParam = nil
        case UInt8(ascii: "<"), UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "?"):
            if params.isEmpty && currentGroup.isEmpty && currentParam == nil {
                privateMarker = byte
            }
        case 0x20...0x2F:
            intermediates.append(byte)
        case 0x40...0x7E:
            if currentParam != nil || !currentGroup.isEmpty || !params.isEmpty {
                currentGroup.append(currentParam ?? -1)
                params.append(currentGroup)
            }
            state = .ground
            csiDispatch(byte)
        default:
            break
        }
    }

    /// The n-th parameter (first sub-parameter), or `def` when missing/zero.
    private func param(_ i: Int, _ def: Int = 1) -> Int {
        guard i < params.count, let v = params[i].first, v > 0 else { return def }
        return v
    }

    /// The n-th parameter allowing 0 as an explicit value.
    private func rawParam(_ i: Int, _ def: Int = 0) -> Int {
        guard i < params.count, let v = params[i].first, v >= 0 else { return def }
        return v
    }

    private func csiDispatch(_ final: UInt8) {
        if privateMarker == UInt8(ascii: "?") {
            switch final {
            case UInt8(ascii: "h"): setPrivateModes(true)
            case UInt8(ascii: "l"): setPrivateModes(false)
            case UInt8(ascii: "J"): eraseInDisplay(rawParam(0))
            case UInt8(ascii: "K"): eraseInLine(rawParam(0))
            default: break
            }
            return
        }
        if privateMarker == UInt8(ascii: ">") {
            if final == UInt8(ascii: "c") {
                respond("\u{1B}[>0;276;0c")
            }
            return
        }
        if privateMarker != 0 { return }

        if let inter = intermediates.first {
            if inter == UInt8(ascii: " ") && final == UInt8(ascii: "q") {
                setCursorStyle(rawParam(0))
            } else if inter == UInt8(ascii: "!") && final == UInt8(ascii: "p") {
                softReset()
            }
            return
        }

        switch final {
        case UInt8(ascii: "@"): insertBlankCells(param(0))
        case UInt8(ascii: "A"): moveCursor(rows: -param(0))
        case UInt8(ascii: "B"), UInt8(ascii: "e"): moveCursor(rows: param(0))
        case UInt8(ascii: "C"), UInt8(ascii: "a"): moveCursor(columns: param(0))
        case UInt8(ascii: "D"): moveCursor(columns: -param(0))
        case UInt8(ascii: "E"):
            moveCursor(rows: param(0)); cursor.column = 0
        case UInt8(ascii: "F"):
            moveCursor(rows: -param(0)); cursor.column = 0
        case UInt8(ascii: "G"), UInt8(ascii: "`"):
            setCursor(column: param(0) - 1, row: nil)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            setCursorAddressed(row: param(0) - 1, column: param(1) - 1)
        case UInt8(ascii: "I"): tabForward(param(0))
        case UInt8(ascii: "J"): eraseInDisplay(rawParam(0))
        case UInt8(ascii: "K"): eraseInLine(rawParam(0))
        case UInt8(ascii: "L"): insertLines(param(0))
        case UInt8(ascii: "M"): deleteLines(param(0))
        case UInt8(ascii: "P"): deleteCells(param(0))
        case UInt8(ascii: "S"): scrollUp(param(0))
        case UInt8(ascii: "T"): scrollDown(param(0))
        case UInt8(ascii: "X"): eraseCells(param(0))
        case UInt8(ascii: "Z"): tabBackward(param(0))
        case UInt8(ascii: "b"):
            if let s = lastPrinted {
                for _ in 0..<min(param(0), columns * rows) { printScalar(s) }
            }
        case UInt8(ascii: "c"):
            if rawParam(0) == 0 { respond("\u{1B}[?62;22c") }
        case UInt8(ascii: "d"):
            setCursorAddressed(row: param(0) - 1, column: cursor.column)
        case UInt8(ascii: "g"):
            switch rawParam(0) {
            case 0: tabStops[cursor.column] = false
            case 3: tabStops = Array(repeating: false, count: columns)
            default: break
            }
        case UInt8(ascii: "h"): setANSIModes(true)
        case UInt8(ascii: "l"): setANSIModes(false)
        case UInt8(ascii: "m"): selectGraphicRendition()
        case UInt8(ascii: "n"):
            switch rawParam(0) {
            case 5: respond("\u{1B}[0n")
            case 6:
                let row = originMode ? cursor.row - scrollTop : cursor.row
                respond("\u{1B}[\(row + 1);\(cursor.column + 1)R")
            default: break
            }
        case UInt8(ascii: "r"):
            setScrollRegion(top: param(0) - 1, bottom: param(1, rows) - 1)
        case UInt8(ascii: "s"): saveCursor()
        case UInt8(ascii: "u"): restoreCursor()
        case UInt8(ascii: "t"):
            if rawParam(0) == 18 { respond("\u{1B}[8;\(rows);\(columns)t") }
        default:
            break
        }
    }

    private func respond(_ s: String) {
        onResponse?(Array(s.utf8))
    }

    // MARK: Modes

    private func setANSIModes(_ on: Bool) {
        for group in params {
            switch group.first ?? -1 {
            case 4: insertMode = on
            case 20: newLineMode = on
            default: break
            }
        }
    }

    private func setPrivateModes(_ on: Bool) {
        for group in params {
            switch group.first ?? -1 {
            case 1: applicationCursorKeys = on
            case 5: reverseVideo = on
            case 6:
                originMode = on
                setCursorAddressed(row: 0, column: 0)
            case 7: autoWrap = on
            case 12: cursorBlinks = on
            case 25: cursorVisible = on
            case 47: switchScreen(alternate: on, clearAlternate: false, saveCursor: false)
            case 1047: switchScreen(alternate: on, clearAlternate: true, saveCursor: false)
            case 1048: if on { saveCursor() } else { restoreCursor() }
            case 1049: switchScreen(alternate: on, clearAlternate: true, saveCursor: true)
            case 1000: mouseTracking = on ? .press : .none
            case 1002: mouseTracking = on ? .buttonMotion : .none
            case 1003: mouseTracking = on ? .anyMotion : .none
            case 1004: focusReporting = on
            case 1006: sgrMouse = on
            case 2004: bracketedPaste = on
            default: break
            }
        }
    }

    private func setCursorStyle(_ n: Int) {
        switch n {
        case 0, 1: cursorShape = .block; cursorBlinks = true
        case 2: cursorShape = .block; cursorBlinks = false
        case 3: cursorShape = .underline; cursorBlinks = true
        case 4: cursorShape = .underline; cursorBlinks = false
        case 5: cursorShape = .bar; cursorBlinks = true
        case 6: cursorShape = .bar; cursorBlinks = false
        default: break
        }
    }

    private func switchScreen(alternate: Bool, clearAlternate: Bool, saveCursor save: Bool) {
        guard alternate != isAlternateScreen else {
            if alternate && clearAlternate { eraseInDisplay(2) }
            return
        }
        if alternate {
            if save { saveCursor() }
            mainScreenWhileAlt = screen
            isAlternateScreen = true
            screen = Array(repeating: TerminalLine(columns: columns), count: rows)
        } else {
            if clearAlternate {
                screen = Array(repeating: TerminalLine(columns: columns), count: rows)
            }
            if let main = mainScreenWhileAlt { screen = main }
            mainScreenWhileAlt = nil
            isAlternateScreen = false
            if save { restoreCursor() }
        }
        pendingWrap = false
        scrollTop = 0
        scrollBottom = rows - 1
    }

    // MARK: SGR

    private func selectGraphicRendition() {
        if params.isEmpty {
            attributes = .plain
            return
        }
        var i = 0
        while i < params.count {
            let group = params[i]
            let p = group.first ?? -1
            switch p {
            case -1, 0: attributes = .plain
            case 1: attributes.flags.insert(.bold)
            case 2: attributes.flags.insert(.dim)
            case 3: attributes.flags.insert(.italic)
            case 4:
                if group.count > 1 && group[1] == 0 { attributes.flags.remove(.underline) }
                else { attributes.flags.insert(.underline) }
            case 7: attributes.flags.insert(.inverse)
            case 8: attributes.flags.insert(.hidden)
            case 9: attributes.flags.insert(.strikethrough)
            case 21: attributes.flags.insert(.underline)
            case 22: attributes.flags.subtract([.bold, .dim])
            case 23: attributes.flags.remove(.italic)
            case 24: attributes.flags.remove(.underline)
            case 27: attributes.flags.remove(.inverse)
            case 28: attributes.flags.remove(.hidden)
            case 29: attributes.flags.remove(.strikethrough)
            case 30...37: attributes.foreground = .indexed(UInt8(p - 30))
            case 39: attributes.foreground = .default
            case 40...47: attributes.background = .indexed(UInt8(p - 40))
            case 49: attributes.background = .default
            case 90...97: attributes.foreground = .indexed(UInt8(p - 90 + 8))
            case 100...107: attributes.background = .indexed(UInt8(p - 100 + 8))
            case 38, 48:
                let (color, consumed) = extendedColor(at: i)
                if let color {
                    if p == 38 { attributes.foreground = color } else { attributes.background = color }
                }
                i += consumed
            default: break
            }
            i += 1
        }
    }

    /// Parses `38;5;n`, `38;2;r;g;b` and their colon forms. Returns the colour and
    /// how many *additional* parameter groups were consumed.
    private func extendedColor(at i: Int) -> (TerminalColor?, Int) {
        let group = params[i]
        func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
        if group.count > 1 {
            // Colon form: 38:5:n  /  38:2:r:g:b  /  38:2:cs:r:g:b
            switch group[1] {
            case 5 where group.count >= 3:
                return (.indexed(clamp(group[2])), 0)
            case 2:
                let rgb = Array(group.dropFirst(2).suffix(3))
                if rgb.count == 3 { return (.rgb(clamp(rgb[0]), clamp(rgb[1]), clamp(rgb[2])), 0) }
                return (nil, 0)
            default:
                return (nil, 0)
            }
        }
        guard i + 1 < params.count else { return (nil, 0) }
        let mode = params[i + 1].first ?? -1
        if mode == 5, i + 2 < params.count {
            return (.indexed(clamp(params[i + 2].first ?? 0)), 2)
        }
        if mode == 2, i + 4 < params.count {
            return (.rgb(clamp(params[i + 2].first ?? 0),
                         clamp(params[i + 3].first ?? 0),
                         clamp(params[i + 4].first ?? 0)), 4)
        }
        return (nil, 1)
    }

    // MARK: OSC

    private func oscDispatch() {
        guard let text = String(bytes: oscBuffer, encoding: .utf8) else { return }
        oscBuffer.removeAll(keepingCapacity: true)
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = parts.first.flatMap({ Int($0) }) else { return }
        let value = parts.count > 1 ? String(parts[1]) : ""
        switch code {
        case 0, 2:
            title = value
            onTitleChange?(value)
        case 7:
            if let url = URL(string: value), url.isFileURL {
                currentDirectory = url.path
            } else if value.hasPrefix("/") {
                currentDirectory = value
            }
        default:
            break
        }
    }

    // MARK: Cursor

    private func moveCursor(rows dy: Int = 0, columns dx: Int = 0) {
        pendingWrap = false
        if dy != 0 {
            let inRegion = cursor.row >= scrollTop && cursor.row <= scrollBottom
            let top = inRegion ? scrollTop : 0
            let bottom = inRegion ? scrollBottom : rows - 1
            cursor.row = min(max(cursor.row + dy, top), bottom)
        }
        if dx != 0 {
            cursor.column = min(max(cursor.column + dx, 0), columns - 1)
        }
    }

    private func setCursor(column: Int?, row: Int?) {
        pendingWrap = false
        if let column { cursor.column = min(max(column, 0), columns - 1) }
        if let row { cursor.row = min(max(row, 0), rows - 1) }
    }

    /// CUP/HVP/VPA honouring origin mode.
    private func setCursorAddressed(row: Int, column: Int) {
        pendingWrap = false
        if originMode {
            cursor.row = min(max(row + scrollTop, scrollTop), scrollBottom)
        } else {
            cursor.row = min(max(row, 0), rows - 1)
        }
        cursor.column = min(max(column, 0), columns - 1)
    }

    private func saveCursor() {
        let saved = SavedCursor(position: cursor, attributes: attributes, pendingWrap: pendingWrap,
                                originMode: originMode, charsets: Array(charsets.prefix(2)),
                                activeCharset: activeCharset)
        if isAlternateScreen { savedCursorAlt = saved } else { savedCursorMain = saved }
    }

    private func restoreCursor() {
        let saved = isAlternateScreen ? savedCursorAlt : savedCursorMain
        cursor = CursorPosition(column: min(saved.position.column, columns - 1),
                                row: min(saved.position.row, rows - 1))
        attributes = saved.attributes
        pendingWrap = saved.pendingWrap
        originMode = saved.originMode
        charsets[0] = saved.charsets[0]
        charsets[1] = saved.charsets[1]
        activeCharset = saved.activeCharset
    }

    private func tabForward(_ n: Int) {
        pendingWrap = false
        var count = n
        while count > 0 && cursor.column < columns - 1 {
            cursor.column += 1
            if tabStops[cursor.column] { count -= 1 }
        }
    }

    private func tabBackward(_ n: Int) {
        pendingWrap = false
        var count = n
        while count > 0 && cursor.column > 0 {
            cursor.column -= 1
            if tabStops[cursor.column] { count -= 1 }
        }
    }

    // MARK: Scrolling

    private var blankLine: TerminalLine {
        TerminalLine(columns: columns, fill: Cell.erased(with: attributes))
    }

    /// LF / IND: move down, scrolling the region when at its bottom margin.
    private func index() {
        pendingWrap = false
        if cursor.row == scrollBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursor.row == scrollTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    private func scrollUp(_ n: Int) {
        let count = min(n, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            let removed = screen.remove(at: scrollTop)
            if scrollTop == 0 && !isAlternateScreen && scrollbackLimit > 0 {
                scrollback.append(removed)
            }
            screen.insert(blankLine, at: scrollBottom)
        }
        trimScrollback()
    }

    private func scrollDown(_ n: Int) {
        let count = min(n, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine, at: scrollTop)
        }
    }

    private func trimScrollback() {
        // Trim in batches so the O(n) removal is amortised.
        let slack = max(scrollbackLimit / 10, 64)
        if scrollback.count > scrollbackLimit + slack || (scrollbackLimit == 0 && !scrollback.isEmpty) {
            let excess = scrollback.count - scrollbackLimit
            scrollback.removeFirst(excess)
            discardedLineCount += excess
        }
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        let t = max(top, 0)
        let b = min(bottom, rows - 1)
        guard t < b else { return }
        scrollTop = t
        scrollBottom = b
        setCursorAddressed(row: 0, column: 0)
    }

    public func clearScrollback() {
        discardedLineCount += scrollback.count
        scrollback.removeAll()
        version &+= 1
    }

    // MARK: Editing

    private func eraseInDisplay(_ mode: Int) {
        pendingWrap = false
        switch mode {
        case 0:
            eraseInLine(0)
            if cursor.row + 1 < rows {
                for r in (cursor.row + 1)..<rows { screen[r] = blankLine }
            }
        case 1:
            eraseInLine(1)
            for r in 0..<cursor.row { screen[r] = blankLine }
        case 2:
            for r in 0..<rows { screen[r] = blankLine }
        case 3:
            clearScrollback()
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        pendingWrap = false
        let fill = Cell.erased(with: attributes)
        let row = cursor.row
        switch mode {
        case 0:
            for c in cursor.column..<columns { screen[row].cells[c] = fill }
            screen[row].wrapped = false
        case 1:
            for c in 0...min(cursor.column, columns - 1) { screen[row].cells[c] = fill }
        case 2:
            screen[row] = blankLine
        default:
            break
        }
    }

    private func eraseCells(_ n: Int) {
        pendingWrap = false
        let fill = Cell.erased(with: attributes)
        let end = min(cursor.column + n, columns)
        for c in cursor.column..<end { screen[cursor.row].cells[c] = fill }
    }

    private func insertBlankCells(_ n: Int) {
        let row = cursor.row
        let count = min(n, columns - cursor.column)
        guard count > 0 else { return }
        var cells = screen[row].cells
        cells.removeLast(count)
        cells.insert(contentsOf: Array(repeating: Cell.erased(with: attributes), count: count), at: cursor.column)
        screen[row].cells = cells
    }

    private func deleteCells(_ n: Int) {
        pendingWrap = false
        let row = cursor.row
        let count = min(n, columns - cursor.column)
        guard count > 0 else { return }
        var cells = screen[row].cells
        cells.removeSubrange(cursor.column..<(cursor.column + count))
        cells.append(contentsOf: Array(repeating: Cell.erased(with: attributes), count: count))
        screen[row].cells = cells
    }

    private func insertLines(_ n: Int) {
        guard cursor.row >= scrollTop && cursor.row <= scrollBottom else { return }
        pendingWrap = false
        let count = min(n, scrollBottom - cursor.row + 1)
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine, at: cursor.row)
        }
        cursor.column = 0
    }

    private func deleteLines(_ n: Int) {
        guard cursor.row >= scrollTop && cursor.row <= scrollBottom else { return }
        pendingWrap = false
        let count = min(n, scrollBottom - cursor.row + 1)
        for _ in 0..<count {
            screen.remove(at: cursor.row)
            screen.insert(blankLine, at: scrollBottom)
        }
        cursor.column = 0
    }

    private func screenAlignment() {
        let e = Cell(character: "E")
        screen = Array(repeating: TerminalLine(cells: Array(repeating: e, count: columns)), count: rows)
        cursor = CursorPosition(column: 0, row: 0)
    }

    // MARK: Reset

    private func softReset() {
        cursorVisible = true
        originMode = false
        autoWrap = true
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        scrollTop = 0
        scrollBottom = rows - 1
        attributes = .plain
        charsets = [.ascii, .ascii, .ascii, .ascii]
        activeCharset = 0
        pendingWrap = false
        savedCursorMain = SavedCursor()
        savedCursorAlt = SavedCursor()
    }

    private func fullReset() {
        if isAlternateScreen, let main = mainScreenWhileAlt { screen = main }
        mainScreenWhileAlt = nil
        isAlternateScreen = false
        softReset()
        screen = Array(repeating: TerminalLine(columns: columns), count: rows)
        cursor = CursorPosition(column: 0, row: 0)
        tabStops = TerminalEmulator.defaultTabStops(columns)
        bracketedPaste = false
        mouseTracking = .none
        sgrMouse = false
        focusReporting = false
        reverseVideo = false
        cursorShape = .block
        cursorBlinks = true
        newLineMode = false
        title = ""
    }

    // MARK: Resize

    public func resize(columns newColumns: Int, rows newRows: Int) {
        let c = max(newColumns, 2)
        let r = max(newRows, 2)
        guard c != columns || r != rows else { return }

        func fit(_ line: TerminalLine) -> TerminalLine {
            var l = line
            if l.cells.count > c {
                l.cells.removeLast(l.cells.count - c)
                if l.cells.last?.width == 2 { l.cells[c - 1] = .blank }
            } else if l.cells.count < c {
                l.cells.append(contentsOf: Array(repeating: Cell.blank, count: c - l.cells.count))
            }
            return l
        }

        // Adjust heights. For the main screen we push lines into / pull lines
        // back from the scrollback so content stays anchored to the cursor.
        func resizeHeight(_ grid: inout [TerminalLine], cursorRow: inout Int, useScrollback: Bool) {
            if r < grid.count {
                // Drop blank lines below the cursor first, then scroll off the top.
                var excess = grid.count - r
                while excess > 0 && grid.count - 1 > cursorRow && grid.last?.text.isEmpty == true {
                    grid.removeLast()
                    excess -= 1
                }
                if excess > 0 {
                    let top = Array(grid.prefix(excess))
                    grid.removeFirst(excess)
                    if useScrollback { scrollback.append(contentsOf: top) }
                    cursorRow -= excess
                }
                if grid.count > r { grid.removeLast(grid.count - r) }
            } else if r > grid.count {
                var missing = r - grid.count
                if useScrollback {
                    let pull = min(missing, scrollback.count)
                    if pull > 0 {
                        let restored = scrollback.suffix(pull)
                        scrollback.removeLast(pull)
                        grid.insert(contentsOf: restored, at: 0)
                        cursorRow += pull
                        missing -= pull
                    }
                }
                grid.append(contentsOf: Array(repeating: TerminalLine(columns: c), count: missing))
            }
            cursorRow = min(max(cursorRow, 0), r - 1)
        }

        var row = cursor.row
        if isAlternateScreen {
            resizeHeight(&screen, cursorRow: &row, useScrollback: false)
            if var main = mainScreenWhileAlt {
                var mainRow = savedCursorMain.position.row
                resizeHeight(&main, cursorRow: &mainRow, useScrollback: true)
                savedCursorMain.position.row = mainRow
                mainScreenWhileAlt = main.map(fit)
            }
        } else {
            resizeHeight(&screen, cursorRow: &row, useScrollback: true)
        }
        screen = screen.map(fit)

        columns = c
        rows = r
        cursor.row = row
        cursor.column = min(cursor.column, c - 1)
        savedCursorMain.position.column = min(savedCursorMain.position.column, c - 1)
        savedCursorAlt.position.column = min(savedCursorAlt.position.column, c - 1)
        savedCursorAlt.position.row = min(savedCursorAlt.position.row, r - 1)
        pendingWrap = false
        scrollTop = 0
        scrollBottom = r - 1
        tabStops = TerminalEmulator.defaultTabStops(c)
        trimScrollback()
        version &+= 1
    }
}
