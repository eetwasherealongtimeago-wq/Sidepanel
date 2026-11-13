import AppKit
import SidePanelCore

/// Draws a `TerminalEmulator` and turns keyboard / mouse input into bytes for the PTY.
@MainActor
final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {

    struct GridPoint: Equatable, Comparable {
        var line: Int     // absolute line (includes lines already discarded from scrollback)
        var column: Int
        static func < (a: GridPoint, b: GridPoint) -> Bool {
            (a.line, a.column) < (b.line, b.column)
        }
    }

    let emulator: TerminalEmulator
    var send: (([UInt8]) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onRestartRequest: (() -> Void)?
    var isProcessRunning: () -> Bool = { true }

    var palette = TerminalPalette() { didSet { needsDisplay = true } }
    var optionAsMeta = false
    var cursorBlinkEnabled = true { didSet { resetBlink() } }

    private(set) var font: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private var boldFont: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private var italicFont: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private var boldItalicFont: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private(set) var cellWidth: CGFloat = 7.5
    private(set) var cellHeight: CGFloat = 16
    private var textYOffset: CGFloat = 1
    private let inset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    private(set) var gridColumns = 80
    private(set) var gridRows = 24

    /// Lines scrolled back from the live bottom (0 = following output).
    private var scrollOffset = 0
    private var scrollRemainder: CGFloat = 0
    private var lastHistoryCount = 0

    private var selectionAnchor: GridPoint?
    private var selectionHead: GridPoint?
    private var selectionGranularity = 1

    private var markedText = ""
    private var isFocused = false
    private var windowIsKey = true
    private var blinkVisible = true
    private var blinkTimer: Timer?
    private var bellLevel: CGFloat = 0
    private var bellTimer: Timer?
    private var mouseButtonDown: KeyEncoder.MouseButton?

    init(emulator: TerminalEmulator, fontSize: CGFloat) {
        self.emulator = emulator
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.drawsAsynchronously = true
        setFontSize(fontSize)
        registerForDraggedTypes([.fileURL, .string])
        lastHistoryCount = emulator.scrollback.count + emulator.discardedLineCount
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Font & geometry

    func setFontSize(_ size: CGFloat) {
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
        cellWidth = ("W" as NSString).size(withAttributes: [.font: font]).width
        let natural = ceil(font.ascender - font.descender + font.leading)
        cellHeight = natural + 3
        textYOffset = 1.5
        recomputeGrid()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeGrid()
    }

    private func recomputeGrid() {
        // Ignore transient zero/tiny sizes during layout; they'd squash the shell to 2×2.
        guard bounds.width > cellWidth * 10, bounds.height > cellHeight * 3 else { return }
        let usableW = bounds.width - inset.left - inset.right
        let usableH = bounds.height - inset.top - inset.bottom
        let cols = max(2, Int(floor(usableW / cellWidth)))
        let rows = max(2, Int(floor(usableH / cellHeight)))
        gridColumns = cols
        gridRows = rows
        // Compare with the emulator (not our last value) so the first real layout always propagates.
        guard cols != emulator.columns || rows != emulator.rows, let onResize else { return }
        onResize(cols, rows)
        clampScroll()
        needsDisplay = true
    }

    // MARK: Updates from the session

    /// Called after new output has been fed to the emulator.
    func contentDidChange() {
        let historyCount = emulator.scrollback.count + emulator.discardedLineCount
        if scrollOffset > 0 {
            // Keep the viewport anchored on the text the user scrolled to.
            scrollOffset += historyCount - lastHistoryCount
            clampScroll()
        }
        lastHistoryCount = historyCount
        blinkVisible = true
        needsDisplay = true
    }

    func ringBell() {
        bellLevel = 1
        bellTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(bellStep), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        bellTimer = t
        needsDisplay = true
    }

    @objc private func bellStep() {
        bellLevel -= 0.06
        if bellLevel <= 0 {
            bellLevel = 0
            bellTimer?.invalidate()
            bellTimer = nil
        }
        needsDisplay = true
    }

    private func clampScroll() {
        scrollOffset = min(max(scrollOffset, 0), emulator.scrollback.count)
    }

    func scrollToBottom() {
        if scrollOffset != 0 {
            scrollOffset = 0
            needsDisplay = true
        }
    }

    private func scroll(lines: Int) {
        scrollOffset += lines
        clampScroll()
        needsDisplay = true
    }

    // MARK: Focus & blinking

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        resetBlink()
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        resetBlink()
        needsDisplay = true
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                               name: NSWindow.didResignKeyNotification, object: window)
        windowIsKey = window.isKeyWindow
    }

    @objc private func windowKeyChanged() {
        windowIsKey = window?.isKeyWindow ?? false
        resetBlink()
        needsDisplay = true
    }

    private func resetBlink() {
        blinkVisible = true
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard cursorBlinkEnabled, isFocused, windowIsKey else { return }
        let t = Timer(timeInterval: 0.6, target: self, selector: #selector(blinkTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    @objc private func blinkTick() {
        guard emulator.cursorBlinks else {
            if !blinkVisible { blinkVisible = true; setNeedsDisplay(cursorRect()) }
            return
        }
        blinkVisible.toggle()
        setNeedsDisplay(cursorRect().insetBy(dx: -2, dy: -2))
    }

    private var hasActiveFocus: Bool { isFocused && windowIsKey }

    // MARK: Drawing

    private func cellRect(column: Int, row: Int, width: Int = 1) -> NSRect {
        NSRect(x: inset.left + CGFloat(column) * cellWidth,
               y: inset.top + CGFloat(row) * cellHeight,
               width: cellWidth * CGFloat(width),
               height: cellHeight)
    }

    private func cursorRect() -> NSRect {
        cellRect(column: emulator.cursor.column, row: emulator.cursor.row)
    }

    /// Index (into scrollback + screen) of the top visible line.
    private var firstVisibleLine: Int {
        emulator.scrollback.count - scrollOffset
    }

    private struct ResolvedColors {
        var foreground: NSColor
        var background: NSColor
        var backgroundIsDefault: Bool
    }

    private func resolve(_ a: CellAttributes) -> ResolvedColors {
        var fg = palette.color(a.foreground, isForeground: true)
        var bg = palette.color(a.background, isForeground: false)
        var bgDefault = a.background == .default
        if a.flags.contains(.inverse) != emulator.reverseVideo {
            swap(&fg, &bg)
            bgDefault = false
        }
        if a.flags.contains(.dim) { fg = fg.withAlphaComponent(0.55) }
        if a.flags.contains(.hidden) { fg = bg }
        return ResolvedColors(foreground: fg, background: bg, backgroundIsDefault: bgDefault)
    }

    private func fontFor(_ flags: CellFlags) -> NSFont {
        switch (flags.contains(.bold), flags.contains(.italic)) {
        case (true, true): return boldItalicFont
        case (true, false): return boldFont
        case (false, true): return italicFont
        default: return font
        }
    }

    private func textAttributes(_ a: CellAttributes, color: NSColor) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: fontFor(a.flags),
            .foregroundColor: color,
            .ligature: 0,
        ]
        if a.flags.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if a.flags.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    override func draw(_ dirtyRect: NSRect) {
        let baseBackground = emulator.reverseVideo ? palette.foreground : palette.background
        baseBackground.setFill()
        dirtyRect.fill()

        let first = firstVisibleLine
        let total = emulator.totalLineCount
        let selection = normalizedSelection()

        for row in 0..<emulator.rows {
            let rowRect = NSRect(x: 0, y: inset.top + CGFloat(row) * cellHeight, width: bounds.width, height: cellHeight)
            guard rowRect.intersects(dirtyRect) else { continue }
            let index = first + row
            guard index >= 0 && index < total else { continue }
            let line = emulator.line(at: index)
            drawBackgrounds(line, row: row)
            drawSelection(row: row, absoluteLine: index + emulator.discardedLineCount, selection: selection)
            drawText(line, row: row)
        }

        if scrollOffset == 0 { drawCursor() }
        if !markedText.isEmpty { drawMarkedText() }
        if scrollOffset > 0 { drawScrollIndicator() }
        if bellLevel > 0 {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            palette.cursor.withAlphaComponent(0.7 * bellLevel).setStroke()
            path.stroke()
        }
    }

    private func drawBackgrounds(_ line: TerminalLine, row: Int) {
        let cells = line.cells
        var col = 0
        while col < cells.count {
            let colors = resolve(cells[col].attributes)
            if colors.backgroundIsDefault {
                col += 1
                continue
            }
            var end = col + 1
            while end < cells.count && cells[end].attributes == cells[col].attributes { end += 1 }
            colors.background.setFill()
            cellRect(column: col, row: row, width: end - col).fill()
            col = end
        }
    }

    private func drawSelection(row: Int, absoluteLine: Int, selection: (GridPoint, GridPoint)?) {
        guard let (start, end) = selection, absoluteLine >= start.line, absoluteLine <= end.line else { return }
        let from = absoluteLine == start.line ? start.column : 0
        let to = absoluteLine == end.line ? end.column : emulator.columns
        guard to > from else { return }
        palette.selection.setFill()
        cellRect(column: from, row: row, width: to - from).fill()
    }

    private func drawText(_ line: TerminalLine, row: Int) {
        let cells = line.cells
        let y = inset.top + CGFloat(row) * cellHeight + textYOffset
        var runStart = 0
        var run = ""
        var runAttributes = cells.first?.attributes ?? .plain
        var runIsBlank = true

        func flush(upTo col: Int) {
            defer {
                run = ""
                runIsBlank = true
            }
            guard !run.isEmpty else { return }
            let decorated = runAttributes.flags.contains(.underline) || runAttributes.flags.contains(.strikethrough)
            if runIsBlank && !decorated { return }
            let colors = resolve(runAttributes)
            let string = NSAttributedString(string: run, attributes: textAttributes(runAttributes, color: colors.foreground))
            string.draw(at: NSPoint(x: inset.left + CGFloat(runStart) * cellWidth, y: y))
        }

        var col = 0
        while col < cells.count {
            let cell = cells[col]
            if cell.width == 0 { col += 1; continue }
            let isSimple = cell.width == 1 && (cell.character.asciiValue.map { $0 >= 0x20 && $0 < 0x7F } ?? false)
            if isSimple {
                if run.isEmpty {
                    runStart = col
                    runAttributes = cell.attributes
                } else if cell.attributes != runAttributes {
                    flush(upTo: col)
                    runStart = col
                    runAttributes = cell.attributes
                }
                run.append(cell.character)
                if cell.character != " " { runIsBlank = false }
            } else {
                // Non-ASCII and wide characters are drawn on their own so that
                // font fallback can't shift the rest of the line off the grid.
                flush(upTo: col)
                let colors = resolve(cell.attributes)
                var attrs = textAttributes(cell.attributes, color: colors.foreground)
                let s = String(cell.character)
                let cellBox = cellRect(column: col, row: row, width: Int(cell.width))
                let measured = (s as NSString).size(withAttributes: attrs)
                if measured.width > cellBox.width + 0.5, let f = attrs[.font] as? NSFont {
                    // Shrink oversized fallback glyphs (emoji, symbols) to fit their cells.
                    attrs[.font] = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * cellBox.width / measured.width) ?? f
                }
                let w = (s as NSString).size(withAttributes: attrs).width
                (s as NSString).draw(at: NSPoint(x: cellBox.minX + max(0, (cellBox.width - w) / 2), y: y), withAttributes: attrs)
            }
            col += 1
        }
        flush(upTo: cells.count)
    }

    private func drawCursor() {
        guard emulator.cursorVisible else { return }
        let c = emulator.cursor
        let line = emulator.screen[c.row]
        let cell = c.column < line.cells.count ? line.cells[c.column] : Cell.blank
        let width = cell.width == 2 ? 2 : 1
        let rect = cellRect(column: c.column, row: c.row, width: width)

        guard hasActiveFocus else {
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            palette.cursor.withAlphaComponent(0.6).setStroke()
            path.stroke()
            return
        }
        guard blinkVisible || !emulator.cursorBlinks else { return }

        palette.cursor.setFill()
        switch emulator.cursorShape {
        case .block:
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            if cell.character != " " {
                var attrs = textAttributes(cell.attributes, color: palette.cursorText)
                attrs.removeValue(forKey: .underlineStyle)
                (String(cell.character) as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + textYOffset), withAttributes: attrs)
            }
        case .underline:
            NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
        case .bar:
            NSRect(x: rect.minX, y: rect.minY + 1, width: 2, height: rect.height - 2).fill()
        }
    }

    private func drawMarkedText() {
        let rect = cursorRect()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.foreground,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: palette.cursor,
        ]
        let s = NSAttributedString(string: markedText, attributes: attrs)
        let size = s.size()
        palette.background.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: size.width + 2, height: cellHeight).fill()
        s.draw(at: NSPoint(x: rect.minX, y: rect.minY + textYOffset))
    }

    private func drawScrollIndicator() {
        let total = CGFloat(max(emulator.totalLineCount, 1))
        let visible = CGFloat(emulator.rows)
        let trackHeight = bounds.height - 16
        let thumbHeight = max(24, trackHeight * visible / total)
        let topLine = CGFloat(firstVisibleLine)
        let y = 8 + (trackHeight - thumbHeight) * (topLine / max(total - visible, 1))
        let thumb = NSRect(x: bounds.width - 6, y: y, width: 3, height: thumbHeight)
        palette.foreground.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()

        // "Jump to live" hint.
        let label = NSAttributedString(string: "↓ \(scrollOffset) lines back", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: palette.background,
        ])
        let size = label.size()
        let pill = NSRect(x: bounds.width - size.width - 28, y: bounds.height - size.height - 18,
                          width: size.width + 14, height: size.height + 6)
        palette.cursor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3))
    }

    // MARK: Keyboard

    private static let specialKeys: [UInt16: TerminalKey] = [
        36: .enter, 76: .enter, 48: .tab, 51: .backspace, 117: .forwardDelete, 53: .escape,
        123: .left, 124: .right, 125: .down, 126: .up,
        115: .home, 119: .end, 116: .pageUp, 121: .pageDown, 114: .insert,
        122: .function(1), 120: .function(2), 99: .function(3), 118: .function(4),
        96: .function(5), 97: .function(6), 98: .function(7), 100: .function(8),
        101: .function(9), 109: .function(10), 103: .function(11), 111: .function(12),
    ]

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            handleCommandKey(event, flags: flags)
            return
        }
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        if !isProcessRunning() {
            if event.keyCode == 36 || event.keyCode == 76 { onRestartRequest?() }
            return
        }

        NSCursor.setHiddenUntilMouseMoves(true)

        var mods: KeyModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        if let key = TerminalView.specialKeys[event.keyCode] {
            if handleLocalScrollKey(key, flags: flags) { return }
            prepareForInput()
            if flags == .option {
                // macOS-style word movement, understood by every shell's line editor.
                if key == .left { send?([0x1B, UInt8(ascii: "b")]); return }
                if key == .right { send?([0x1B, UInt8(ascii: "f")]); return }
            }
            send?(KeyEncoder.encode(key, modifiers: mods, applicationCursor: emulator.applicationCursorKeys))
            return
        }

        if flags.contains(.control), let chars = event.charactersIgnoringModifiers, let c = chars.first,
           let code = KeyEncoder.controlCharacter(for: c) {
            prepareForInput()
            send?(flags.contains(.option) ? [0x1B, code] : [code])
            return
        }

        if flags.contains(.option) && optionAsMeta, let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            prepareForInput()
            send?([0x1B] + Array(chars.utf8))
            return
        }

        prepareForInput()
        interpretKeyEvents([event])
    }

    private func prepareForInput() {
        scrollToBottom()
        if selectionAnchor != nil { clearSelection() }
        blinkVisible = true
    }

    /// Shift+PageUp/PageDown/Home/End scroll the history on the primary screen.
    private func handleLocalScrollKey(_ key: TerminalKey, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags == .shift, !emulator.isAlternateScreen else { return false }
        switch key {
        case .pageUp: scroll(lines: max(1, emulator.rows - 1)); return true
        case .pageDown: scroll(lines: -max(1, emulator.rows - 1)); return true
        case .home: scroll(lines: emulator.scrollback.count); return true
        case .end: scrollToBottom(); return true
        default: return false
        }
    }

    private func handleCommandKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) {
        guard isProcessRunning() else { return }
        switch event.keyCode {
        case 123: prepareForInput(); send?([0x01])            // ⌘← start of line
        case 124: prepareForInput(); send?([0x05])            // ⌘→ end of line
        case 51: prepareForInput(); send?([0x15])             // ⌘⌫ delete line
        case 126: scroll(lines: emulator.scrollback.count)    // ⌘↑ top of history
        case 125: scrollToBottom()                            // ⌘↓ back to live
        default: break
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        guard !text.isEmpty else { return }
        send?(Array(text.utf8))
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        // Special keys are encoded in keyDown; swallow the rest instead of beeping.
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let local = convert(cursorRect(), to: nil)
        return window.convertToScreen(local)
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard isProcessRunning(), let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        prepareForInput()
        send?(KeyEncoder.paste(text, bracketed: emulator.bracketedPaste))
    }

    @objc override func selectAll(_ sender: Any?) {
        let firstAbs = emulator.discardedLineCount
        let lastAbs = emulator.discardedLineCount + emulator.totalLineCount - 1
        selectionAnchor = GridPoint(line: firstAbs, column: 0)
        selectionHead = GridPoint(line: lastAbs, column: emulator.columns)
        needsDisplay = true
    }

    @objc func clearScrollback(_ sender: Any?) {
        emulator.clearScrollback()
        scrollOffset = 0
        lastHistoryCount = emulator.discardedLineCount
        needsDisplay = true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return normalizedSelection() != nil
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        default: return true
        }
    }

    // MARK: Selection

    private func normalizedSelection() -> (GridPoint, GridPoint)? {
        guard let a = selectionAnchor, let h = selectionHead, a != h else { return nil }
        return a < h ? (a, h) : (h, a)
    }

    func clearSelection() {
        selectionAnchor = nil
        selectionHead = nil
        needsDisplay = true
    }

    func selectedText() -> String? {
        guard let (s, e) = normalizedSelection() else { return nil }
        let d = emulator.discardedLineCount
        return emulator.text(from: (s.line - d, s.column), to: (e.line - d, e.column))
    }

    private func gridPoint(at point: NSPoint, rounding: Bool) -> GridPoint {
        let rawCol = (point.x - inset.left) / cellWidth
        let col = rounding ? Int(rawCol.rounded()) : Int(floor(rawCol))
        let row = Int(floor((point.y - inset.top) / cellHeight))
        let clampedRow = min(max(row, 0), emulator.rows - 1)
        let line = firstVisibleLine + clampedRow + emulator.discardedLineCount
        return GridPoint(line: line, column: min(max(col, 0), emulator.columns))
    }

    private func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "-_.~/:@%+#?=&".contains(c)
    }

    private func expandToWord(_ p: GridPoint) -> (GridPoint, GridPoint) {
        let index = p.line - emulator.discardedLineCount
        guard index >= 0 && index < emulator.totalLineCount else { return (p, p) }
        let cells = emulator.line(at: index).cells
        guard p.column < cells.count else { return (p, p) }
        let pivot = cells[p.column].character
        func characterClass(_ c: Character) -> Int { c == " " ? 0 : (isWordCharacter(c) ? 1 : 2) }
        let pivotClass = characterClass(pivot)
        func sameClass(_ c: Character) -> Bool {
            pivotClass == 2 ? c == pivot : characterClass(c) == pivotClass
        }
        var start = p.column
        var end = p.column
        while start > 0 && sameClass(cells[start - 1].character) { start -= 1 }
        while end < cells.count && sameClass(cells[end].character) { end += 1 }
        return (GridPoint(line: p.line, column: start), GridPoint(line: p.line, column: max(end, start + 1)))
    }

    // MARK: Mouse

    private var reportsMouse: Bool {
        emulator.mouseTracking != .none
    }

    private func mouseModifiers(_ event: NSEvent) -> KeyModifiers {
        var m: KeyModifiers = []
        if event.modifierFlags.contains(.option) { m.insert(.option) }
        if event.modifierFlags.contains(.control) { m.insert(.control) }
        return m
    }

    private func reportMouse(_ button: KeyEncoder.MouseButton, event: NSEvent, pressed: Bool, motion: Bool = false) {
        let p = convert(event.locationInWindow, from: nil)
        let col = min(max(Int((p.x - inset.left) / cellWidth), 0), emulator.columns - 1)
        let row = min(max(Int((p.y - inset.top) / cellHeight), 0), emulator.rows - 1)
        send?(KeyEncoder.mouse(button, column: col, row: row, pressed: pressed, motion: motion,
                               modifiers: mouseModifiers(event), sgr: emulator.sgrMouse))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportsMouse && !event.modifierFlags.contains(.shift) {
            mouseButtonDown = .left
            reportMouse(.left, event: event, pressed: true)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let point = gridPoint(at: p, rounding: true)
        selectionGranularity = event.clickCount
        switch event.clickCount {
        case 2:
            let (s, e) = expandToWord(gridPoint(at: p, rounding: false))
            selectionAnchor = s
            selectionHead = e
        case 3...:
            selectionAnchor = GridPoint(line: point.line, column: 0)
            selectionHead = GridPoint(line: point.line, column: emulator.columns)
        default:
            if event.modifierFlags.contains(.shift), selectionAnchor != nil {
                selectionHead = point
            } else {
                selectionAnchor = point
                selectionHead = point
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let button = mouseButtonDown {
            if emulator.mouseTracking == .buttonMotion || emulator.mouseTracking == .anyMotion {
                reportMouse(button, event: event, pressed: true, motion: true)
            }
            return
        }
        guard selectionAnchor != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Auto-scroll when dragging past the edges.
        if p.y < inset.top { scroll(lines: 1) }
        else if p.y > bounds.height - inset.bottom { scroll(lines: -1) }
        var head = gridPoint(at: p, rounding: true)
        if selectionGranularity >= 3 {
            head.column = head < (selectionAnchor ?? head) ? 0 : emulator.columns
        } else if selectionGranularity == 2 {
            let (s, e) = expandToWord(gridPoint(at: p, rounding: false))
            head = head < (selectionAnchor ?? head) ? s : e
        }
        selectionHead = head
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let button = mouseButtonDown {
            reportMouse(button, event: event, pressed: false)
            mouseButtonDown = nil
            return
        }
        if normalizedSelection() == nil { clearSelection() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse && !event.modifierFlags.contains(.shift) {
            reportMouse(.right, event: event, pressed: true)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportsMouse && !event.modifierFlags.contains(.shift) {
            reportMouse(.right, event: event, pressed: false)
            return
        }
        super.rightMouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Scrollback", action: #selector(clearScrollback(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    override func scrollWheel(with event: NSEvent) {
        let lineDelta: CGFloat
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += event.scrollingDeltaY / cellHeight
            lineDelta = scrollRemainder.rounded(.towardZero)
            scrollRemainder -= lineDelta
        } else {
            lineDelta = event.scrollingDeltaY.rounded(.awayFromZero) * 3
        }
        let lines = Int(lineDelta)
        guard lines != 0 else { return }

        if emulator.isAlternateScreen || reportsMouse {
            if reportsMouse {
                let button: KeyEncoder.MouseButton = lines > 0 ? .wheelUp : .wheelDown
                for _ in 0..<min(abs(lines), 10) { reportMouse(button, event: event, pressed: true) }
            } else {
                // "Alternate scroll": full-screen apps without mouse support get arrow keys.
                let key: TerminalKey = lines > 0 ? .up : .down
                let bytes = KeyEncoder.encode(key, applicationCursor: emulator.applicationCursorKeys)
                for _ in 0..<min(abs(lines), 10) { send?(bytes) }
            }
            return
        }
        scroll(lines: lines)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: Drag and drop (files become shell-quoted paths)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isProcessRunning() ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let text = urls.map { TerminalView.shellQuote($0.path) }.joined(separator: " ") + " "
            send?(Array(text.utf8))
            window?.makeFirstResponder(self)
            return true
        }
        if let s = pb.string(forType: .string) {
            send?(KeyEncoder.paste(s, bracketed: emulator.bracketedPaste))
            return true
        }
        return false
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,:@%"))
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityValue() -> Any? { emulator.screenText }
}
