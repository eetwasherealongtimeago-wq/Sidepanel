import AppKit
import SidePanelCore

/// SidePanel's terminal colour scheme ("Graphite"), plus resolution of the
/// 256-colour and true-colour spaces to NSColor.
struct TerminalPalette {
    var foreground = NSColor(hex: 0xD9DDE7)
    var background = NSColor(hex: 0x0B0C10)
    var cursor = NSColor(hex: 0x6EF2C2)
    var cursorText = NSColor(hex: 0x0B0C10)
    var selection = NSColor(hex: 0x6EF2C2, alpha: 0.24)
    var ansi: [NSColor] = [
        NSColor(hex: 0x1C1F27), // black
        NSColor(hex: 0xFF6F7D), // red
        NSColor(hex: 0x6EF2C2), // green (signal mint)
        NSColor(hex: 0xFFC46B), // yellow
        NSColor(hex: 0x6EA8FF), // blue
        NSColor(hex: 0x9A8CFF), // magenta (dusk violet)
        NSColor(hex: 0x58D3F5), // cyan
        NSColor(hex: 0xC9CED9), // white
        NSColor(hex: 0x4A5061), // bright black
        NSColor(hex: 0xFF94A0), // bright red
        NSColor(hex: 0x9DF7D7), // bright green
        NSColor(hex: 0xFFD794), // bright yellow
        NSColor(hex: 0x96C0FF), // bright blue
        NSColor(hex: 0xBDB3FF), // bright magenta
        NSColor(hex: 0x8DE3FA), // bright cyan
        NSColor(hex: 0xF4F6FA), // bright white
    ]

    private var cache: [NSColor] = []

    init() {
        cache = (0..<256).map { TerminalPalette.xterm256($0, ansi: ansi) }
    }

    private static func xterm256(_ i: Int, ansi: [NSColor]) -> NSColor {
        if i < 16 { return ansi[i] }
        if i < 232 {
            let n = i - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: steps[(n / 36) % 6] / 255, green: steps[(n / 6) % 6] / 255,
                           blue: steps[n % 6] / 255, alpha: 1)
        }
        let level = CGFloat(8 + (i - 232) * 10) / 255
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    }

    func color(_ c: TerminalColor, isForeground: Bool) -> NSColor {
        switch c {
        case .default: return isForeground ? foreground : background
        case .indexed(let i): return cache[Int(i)]
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }
}
