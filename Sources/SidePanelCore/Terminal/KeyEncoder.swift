import Foundation

/// Keys that have no printable representation and must be encoded as escape sequences.
public enum TerminalKey: Equatable, Sendable {
    case up, down, right, left
    case home, end, pageUp, pageDown, insert, forwardDelete
    case backspace, tab, enter, escape
    case function(Int)
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)

    /// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    var xtermParameter: Int {
        1 + (contains(.shift) ? 1 : 0) + (contains(.option) ? 2 : 0) + (contains(.control) ? 4 : 0)
    }
}

/// Translates keyboard input into the byte sequences an xterm sends.
public enum KeyEncoder {
    private static let esc: UInt8 = 0x1B

    public static func encode(_ key: TerminalKey, modifiers: KeyModifiers = [], applicationCursor: Bool = false) -> [UInt8] {
        let m = modifiers.xtermParameter
        func csi(_ s: String) -> [UInt8] { [esc, UInt8(ascii: "[")] + Array(s.utf8) }
        func ss3(_ c: Character) -> [UInt8] { [esc, UInt8(ascii: "O"), c.asciiValue!] }

        func cursorKey(_ c: Character) -> [UInt8] {
            if m > 1 { return csi("1;\(m)\(c)") }
            return applicationCursor ? ss3(c) : csi(String(c))
        }
        func tildeKey(_ n: Int) -> [UInt8] {
            m > 1 ? csi("\(n);\(m)~") : csi("\(n)~")
        }

        switch key {
        case .up: return cursorKey("A")
        case .down: return cursorKey("B")
        case .right: return cursorKey("C")
        case .left: return cursorKey("D")
        case .home: return cursorKey("H")
        case .end: return cursorKey("F")
        case .insert: return tildeKey(2)
        case .forwardDelete: return tildeKey(3)
        case .pageUp: return tildeKey(5)
        case .pageDown: return tildeKey(6)
        case .backspace:
            if modifiers.contains(.control) { return [0x08] }
            return modifiers.contains(.option) ? [esc, 0x7F] : [0x7F]
        case .tab:
            return modifiers.contains(.shift) ? csi("Z") : [0x09]
        case .enter:
            return modifiers.contains(.option) ? [esc, 0x0D] : [0x0D]
        case .escape:
            return [esc]
        case .function(let n):
            switch n {
            case 1...4:
                let c: Character = ["P", "Q", "R", "S"][n - 1]
                return m > 1 ? csi("1;\(m)\(c)") : ss3(c)
            case 5...12:
                let codes = [15, 17, 18, 19, 20, 21, 23, 24]
                return tildeKey(codes[n - 5])
            default:
                return []
            }
        }
    }

    /// The control character produced by Ctrl + `character`, if any.
    public static func controlCharacter(for character: Character) -> UInt8? {
        guard let ascii = character.lowercased().first?.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return ascii - UInt8(ascii: "a") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "2"): return 0
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "7"): return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
        default: return nil
        }
    }

    /// Wraps pasted text in bracketed-paste markers when the application asked for them,
    /// normalising newlines to carriage returns as a real keyboard would.
    public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\r")
        normalized = normalized.replacingOccurrences(of: "\n", with: "\r")
        if bracketed {
            // Strip any embedded end marker so pasted text can't escape the bracket.
            normalized = normalized.replacingOccurrences(of: "\u{1B}[201~", with: "")
            return Array("\u{1B}[200~".utf8) + Array(normalized.utf8) + Array("\u{1B}[201~".utf8)
        }
        return Array(normalized.utf8)
    }

    public enum MouseButton: Int, Sendable {
        case left = 0, middle = 1, right = 2, release = 3, wheelUp = 64, wheelDown = 65
    }

    /// Encodes a mouse report. Coordinates are zero-based cells.
    public static func mouse(_ button: MouseButton, column: Int, row: Int, pressed: Bool,
                             motion: Bool = false, modifiers: KeyModifiers = [], sgr: Bool) -> [UInt8] {
        var code = button.rawValue
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        if motion { code += 32 }
        if sgr {
            let final = pressed ? "M" : "m"
            return Array("\u{1B}[<\(code);\(column + 1);\(row + 1)\(final)".utf8)
        }
        let b = pressed ? code : (3 + (code & ~3))
        func coord(_ v: Int) -> UInt8 { UInt8(min(v + 33, 255)) }
        return [esc, UInt8(ascii: "["), UInt8(ascii: "M"), UInt8(min(b + 32, 255)), coord(column), coord(row)]
    }
}
