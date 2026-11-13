import AppKit
import SwiftUI

/// SidePanel's visual identity: graphite surfaces, a mint "signal" accent and a
/// violet counter-accent. Everything visual reads from here.
enum Theme {
    // Surfaces
    static let canvas        = Color(hex: 0x0B0C10)
    static let surface       = Color(hex: 0x12141A)
    static let surfaceRaised = Color(hex: 0x1A1D25)
    static let surfaceHover  = Color(hex: 0x222632)
    static let hairline      = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.12)

    // Text
    static let textPrimary   = Color(hex: 0xE9EBF1)
    static let textSecondary = Color(hex: 0x9097A8)
    static let textTertiary  = Color(hex: 0x5D6476)

    // Accents
    static let accent        = Color(hex: 0x6EF2C2)   // signal mint
    static let accentAlt     = Color(hex: 0x9A8CFF)   // dusk violet
    static let warning       = Color(hex: 0xFFC46B)
    static let danger        = Color(hex: 0xFF6F7D)

    static let accentGradient = LinearGradient(colors: [accent, Color(hex: 0x58D3F5)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)

    // Geometry
    static let panelCorner: CGFloat = 16
    static let controlCorner: CGFloat = 8
    static let headerHeight: CGFloat = 40

    // Motion
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let gentle = Animation.easeOut(duration: 0.18)

    // Typography
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Deterministic tint for letter avatars (tabs, bookmarks).
    static func tint(for seed: String) -> Color {
        let palette: [UInt32] = [0x6EF2C2, 0x9A8CFF, 0x58D3F5, 0xFFC46B, 0xFF8FB1, 0xA6E36F, 0xF59E6C]
        var hash: UInt32 = 2166136261
        for b in seed.utf8 { hash = (hash ^ UInt32(b)) &* 16777619 }
        return Color(hex: palette[Int(hash % UInt32(palette.count))])
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: Reusable controls

/// Small square icon button used throughout the chrome.
struct GlyphButton: View {
    let glyph: Glyph
    var size: CGFloat = 26
    var iconSize: CGFloat = 13
    var isActive = false
    var isEnabled = true
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            GlyphView(glyph: glyph, size: iconSize)
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlCorner - 1, style: .continuous)
                        .fill(hovering && isEnabled ? Theme.surfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var foreground: Color {
        if !isEnabled { return Theme.textTertiary.opacity(0.6) }
        if isActive { return Theme.accent }
        return hovering ? Theme.textPrimary : Theme.textSecondary
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Pill button with text, used in settings and empty states.
struct PillButton: View {
    let title: String
    var glyph: Glyph? = nil
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let glyph { GlyphView(glyph: glyph, size: 11) }
                Text(title).font(Theme.ui(12, .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Theme.textPrimary)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Theme.accentGradient)
                                    : AnyShapeStyle(hovering ? Theme.surfaceHover : Theme.surfaceRaised))
            )
            .overlay(Capsule(style: .continuous).stroke(prominent ? Color.clear : Theme.hairline))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

/// Letter avatar (stands in for favicons and session glyphs).
struct LetterAvatar: View {
    let text: String
    var size: CGFloat = 16

    var body: some View {
        let letter = text.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "•"
        let tint = Theme.tint(for: text)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(tint.opacity(0.18))
            .overlay(
                Text(letter)
                    .font(.system(size: size * 0.58, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
    }
}
