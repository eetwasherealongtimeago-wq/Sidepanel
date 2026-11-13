import SwiftUI

/// SidePanel's own line-icon set. Each glyph is drawn on a 24×24 grid and
/// stroked with rounded caps so the whole set shares one visual weight.
enum Glyph: CaseIterable {
    case browser, terminal, back, forward, reload, stop, plus, close
    case bookmark, bookmarkFilled, library, download, history, gear, pin, pinFilled
    case hide, search, lock, globe, trash, folder, open, edge, keyboard, sparkle, chevronDown

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s
        let oy = rect.midY - 12 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        var path = Path()
        switch self {
        case .browser:
            // A planet with a tilted orbit — "the web" without the usual globe grid.
            path.addEllipse(in: r(6.5, 6.5, 11, 11))
            path.addPath(Path(ellipseIn: r(1.5, 9, 21, 6))
                .applying(CGAffineTransform(translationX: -(ox + 12 * s), y: -(oy + 12 * s))
                    .concatenating(CGAffineTransform(rotationAngle: -.pi / 7))
                    .concatenating(CGAffineTransform(translationX: ox + 12 * s, y: oy + 12 * s))))
        case .terminal:
            path.addRoundedRect(in: r(2.5, 4, 19, 16), cornerSize: CGSize(width: 3.5 * s, height: 3.5 * s))
            path.move(to: p(7, 9.5)); path.addLine(to: p(10, 12)); path.addLine(to: p(7, 14.5))
            path.move(to: p(12.5, 15)); path.addLine(to: p(17, 15))
        case .back:
            path.move(to: p(14.5, 6)); path.addLine(to: p(8.5, 12)); path.addLine(to: p(14.5, 18))
        case .forward:
            path.move(to: p(9.5, 6)); path.addLine(to: p(15.5, 12)); path.addLine(to: p(9.5, 18))
        case .reload:
            path.addArc(center: p(12, 12), radius: 7 * s, startAngle: .degrees(-60), endAngle: .degrees(250), clockwise: false)
            path.move(to: p(15.6, 3.6)); path.addLine(to: p(15.6, 6.8)); path.addLine(to: p(18.8, 6.8))
        case .stop, .close:
            let inset: CGFloat = self == .stop ? 7 : 7.5
            path.move(to: p(inset, inset)); path.addLine(to: p(24 - inset, 24 - inset))
            path.move(to: p(24 - inset, inset)); path.addLine(to: p(inset, 24 - inset))
        case .plus:
            path.move(to: p(12, 5.5)); path.addLine(to: p(12, 18.5))
            path.move(to: p(5.5, 12)); path.addLine(to: p(18.5, 12))
        case .bookmark, .bookmarkFilled:
            path.move(to: p(7, 4)); path.addLine(to: p(17, 4)); path.addLine(to: p(17, 20))
            path.addLine(to: p(12, 16)); path.addLine(to: p(7, 20)); path.closeSubpath()
        case .library:
            path.addRoundedRect(in: r(3.5, 4, 5, 16), cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
            path.addRoundedRect(in: r(10, 4, 5, 16), cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
            path.move(to: p(17, 5.5)); path.addLine(to: p(20.5, 19))
        case .download:
            path.move(to: p(12, 4)); path.addLine(to: p(12, 14.5))
            path.move(to: p(7.5, 10.5)); path.addLine(to: p(12, 15)); path.addLine(to: p(16.5, 10.5))
            path.move(to: p(5, 16.5)); path.addLine(to: p(5, 19.5)); path.addLine(to: p(19, 19.5)); path.addLine(to: p(19, 16.5))
        case .history:
            path.addArc(center: p(12, 12), radius: 8 * s, startAngle: .degrees(200), endAngle: .degrees(560), clockwise: false)
            path.move(to: p(12, 7.5)); path.addLine(to: p(12, 12)); path.addLine(to: p(15, 14))
            path.move(to: p(2.8, 9.5)); path.addLine(to: p(4.6, 11.4)); path.addLine(to: p(6.6, 9.8))
        case .gear:
            // Six soft lobes around a hub — a calmer take on a cog.
            for i in 0..<6 {
                let a = Double(i) * .pi / 3
                let c = p(12 + 6.2 * CGFloat(cos(a)), 12 + 6.2 * CGFloat(sin(a)))
                path.addEllipse(in: CGRect(x: c.x - 2.6 * s, y: c.y - 2.6 * s, width: 5.2 * s, height: 5.2 * s))
            }
            path.addEllipse(in: r(9.5, 9.5, 5, 5))
        case .pin, .pinFilled:
            path.move(to: p(9, 4)); path.addLine(to: p(15, 4))
            path.move(to: p(10, 4)); path.addLine(to: p(9.5, 10)); path.addLine(to: p(7, 13.5))
            path.addLine(to: p(17, 13.5)); path.addLine(to: p(14.5, 10)); path.addLine(to: p(14, 4))
            path.move(to: p(12, 13.5)); path.addLine(to: p(12, 20.5))
        case .hide:
            path.move(to: p(9, 6)); path.addLine(to: p(15, 12)); path.addLine(to: p(9, 18))
            path.move(to: p(19, 5)); path.addLine(to: p(19, 19))
        case .search:
            path.addEllipse(in: r(4.5, 4.5, 11, 11))
            path.move(to: p(14, 14)); path.addLine(to: p(19.5, 19.5))
        case .lock:
            path.addRoundedRect(in: r(5.5, 10.5, 13, 9.5), cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
            path.move(to: p(8.5, 10.5)); path.addLine(to: p(8.5, 8))
            path.addArc(center: p(12, 8), radius: 3.5 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: p(15.5, 10.5))
        case .globe:
            path.addEllipse(in: r(4, 4, 16, 16))
            path.move(to: p(4.5, 12)); path.addLine(to: p(19.5, 12))
            path.addEllipse(in: r(8.5, 4, 7, 16))
        case .trash:
            path.move(to: p(4.5, 7)); path.addLine(to: p(19.5, 7))
            path.move(to: p(9.5, 7)); path.addLine(to: p(10, 4.5)); path.addLine(to: p(14, 4.5)); path.addLine(to: p(14.5, 7))
            path.move(to: p(6.5, 7)); path.addLine(to: p(7.5, 19.5)); path.addLine(to: p(16.5, 19.5)); path.addLine(to: p(17.5, 7))
        case .folder:
            path.move(to: p(3.5, 7)); path.addLine(to: p(3.5, 18.5)); path.addLine(to: p(20.5, 18.5)); path.addLine(to: p(20.5, 8.5))
            path.addLine(to: p(11.5, 8.5)); path.addLine(to: p(9.5, 5.5)); path.addLine(to: p(3.5, 5.5)); path.closeSubpath()
        case .open:
            path.move(to: p(13, 4.5)); path.addLine(to: p(19.5, 4.5)); path.addLine(to: p(19.5, 11))
            path.move(to: p(19.5, 4.5)); path.addLine(to: p(11, 13))
            path.move(to: p(16.5, 14)); path.addLine(to: p(16.5, 19.5)); path.addLine(to: p(4.5, 19.5))
            path.addLine(to: p(4.5, 7.5)); path.addLine(to: p(10, 7.5))
        case .edge:
            path.addRoundedRect(in: r(3, 4, 18, 16), cornerSize: CGSize(width: 3 * s, height: 3 * s))
            path.move(to: p(15, 4)); path.addLine(to: p(15, 20))
        case .keyboard:
            path.addRoundedRect(in: r(2.5, 6, 19, 12), cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
            for x in stride(from: 6.5, through: 17.5, by: 3.66) {
                path.move(to: p(CGFloat(x), 10)); path.addLine(to: p(CGFloat(x) + 0.01, 10))
            }
            path.move(to: p(8, 14)); path.addLine(to: p(16, 14))
        case .sparkle:
            path.move(to: p(12, 3.5))
            path.addQuadCurve(to: p(20.5, 12), control: p(13, 11))
            path.addQuadCurve(to: p(12, 20.5), control: p(13, 13))
            path.addQuadCurve(to: p(3.5, 12), control: p(11, 13))
            path.addQuadCurve(to: p(12, 3.5), control: p(11, 11))
        case .chevronDown:
            path.move(to: p(7, 10)); path.addLine(to: p(12, 15)); path.addLine(to: p(17, 10))
        }
        return path
    }

    var isFilled: Bool {
        self == .bookmarkFilled || self == .pinFilled || self == .sparkle
    }
}

struct GlyphShape: Shape {
    let glyph: Glyph
    func path(in rect: CGRect) -> Path { glyph.path(in: rect) }
}

struct GlyphView: View {
    let glyph: Glyph
    var size: CGFloat = 14
    var weight: CGFloat = 1.0

    var body: some View {
        let line = max(1.1, size / 24 * 2.0 * weight)
        ZStack {
            if glyph.isFilled {
                GlyphShape(glyph: glyph).fill()
            }
            GlyphShape(glyph: glyph)
                .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}
