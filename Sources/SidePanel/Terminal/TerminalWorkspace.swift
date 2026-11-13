import SwiftUI

struct TerminalWorkspace: View {
    @EnvironmentObject var terminals: TerminalManager
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(
                tabs: terminals.sessions.map { s in
                    TabPillModel(id: s.id, title: s.title, avatarSeed: s.isRunning ? "›" : "×",
                                 hasBadge: s.hasUnseenOutput, monospaced: true)
                },
                selectedID: terminals.selected?.id,
                onSelect: { id in if let s = terminals.sessions.first(where: { $0.id == id }) { terminals.select(s); focus() } },
                onClose: { id in if let s = terminals.sessions.first(where: { $0.id == id }) { withAnimation(Theme.snappy) { terminals.close(s) } } },
                onNew: { withAnimation(Theme.snappy) { terminals.newSession() }; focus() },
                onMove: { terminals.moveSession($0, before: $1) }
            )
            .padding(.top, 2)
            .padding(.bottom, 6)

            ZStack {
                if let session = terminals.selected {
                    HostedView(view: session.view, isActive: isActive)
                } else {
                    emptyState
                }
            }
            .background(Color(nsColor: TerminalPalette().background))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func focus() {
        DispatchQueue.main.async {
            if let view = terminals.selected?.view { view.window?.makeFirstResponder(view) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            GlyphView(glyph: .terminal, size: 30).foregroundStyle(Theme.accent)
            Text("No shells running")
                .font(Theme.ui(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
            PillButton(title: "New Session", glyph: .plus, prominent: true) {
                terminals.newSession()
                focus()
            }
            Text("⌘T").font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
