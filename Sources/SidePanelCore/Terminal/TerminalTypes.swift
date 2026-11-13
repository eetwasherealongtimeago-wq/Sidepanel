import Foundation

/// A colour as the terminal application asked for it. Concrete RGB values are
/// resolved by the renderer's palette so themes can change without re-parsing.
public enum TerminalColor: Equatable, Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct CellFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold          = CellFlags(rawValue: 1 << 0)
    public static let dim           = CellFlags(rawValue: 1 << 1)
    public static let italic        = CellFlags(rawValue: 1 << 2)
    public static let underline     = CellFlags(rawValue: 1 << 3)
    public static let inverse       = CellFlags(rawValue: 1 << 4)
    public static let hidden        = CellFlags(rawValue: 1 << 5)
    public static let strikethrough = CellFlags(rawValue: 1 << 6)
}

public struct CellAttributes: Equatable, Hashable, Sendable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var flags: CellFlags

    public init(foreground: TerminalColor = .default,
                background: TerminalColor = .default,
                flags: CellFlags = []) {
        self.foreground = foreground
        self.background = background
        self.flags = flags
    }

    public static let plain = CellAttributes()
}

/// One character cell. `width` is 1 for ordinary characters, 2 for the leading
/// half of a wide (CJK / emoji) character and 0 for the trailing half.
public struct Cell: Equatable, Sendable {
    public var character: Character
    public var width: UInt8
    public var attributes: CellAttributes

    public init(character: Character = " ", width: UInt8 = 1, attributes: CellAttributes = .plain) {
        self.character = character
        self.width = width
        self.attributes = attributes
    }

    public static let blank = Cell()

    /// A blank cell that keeps the current background colour (xterm's "BCE").
    static func erased(with attributes: CellAttributes) -> Cell {
        Cell(character: " ", width: 1, attributes: CellAttributes(background: attributes.background))
    }
}

public struct TerminalLine: Equatable, Sendable {
    public var cells: [Cell]
    /// True when the line continues onto the next one because of auto-wrap.
    public var wrapped: Bool

    public init(cells: [Cell], wrapped: Bool = false) {
        self.cells = cells
        self.wrapped = wrapped
    }

    public init(columns: Int, fill: Cell = .blank) {
        self.cells = Array(repeating: fill, count: max(columns, 1))
        self.wrapped = false
    }

    /// The line's text with trailing blanks removed.
    public var text: String {
        var s = String()
        s.reserveCapacity(cells.count)
        for cell in cells where cell.width != 0 { s.append(cell.character) }
        while s.last == " " { s.removeLast() }
        return s
    }
}

public enum CursorShape: Equatable, Sendable {
    case block, underline, bar
}

public struct CursorPosition: Equatable, Sendable {
    public var column: Int
    public var row: Int
    public init(column: Int, row: Int) { self.column = column; self.row = row }
}

public enum MouseTrackingMode: Equatable, Sendable {
    case none
    case press          // 1000
    case buttonMotion   // 1002
    case anyMotion      // 1003
}
