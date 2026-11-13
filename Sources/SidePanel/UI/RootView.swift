import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ZStack {
            Theme.canvas.opacity(0.9)

            VStack(spacing: 0) {
                HeaderBar()
                ZStack {
                    BrowserView(isActive: state.section == .browser)
                        .opacity(state.section == .browser ? 1 : 0)
                        .offset(x: state.section == .browser ? 0 : -12)
                        .allowsHitTesting(state.section == .browser)
                    TerminalWorkspace(isActive: state.section == .terminal)
                        .opacity(state.section == .terminal ? 1 : 0)
                        .offset(x: state.section == .terminal ? 0 : 12)
                        .allowsHitTesting(state.section == .terminal)
                }
                .animation(Theme.snappy, value: state.section)
            }

            if state.showSettings {
                SettingsOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .allowsHitTesting(false)
        )
        .overlay(resizeEdges)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
        .preferredColorScheme(.dark)
        .animation(Theme.gentle, value: state.showSettings)
    }

    /// Thin invisible strips for resizing; the docked edge stays put.
    private var resizeEdges: some View {
        ZStack {
            HStack(spacing: 0) {
                if settings.placement != .left {
                    ResizeEdge(edge: .left).frame(width: 5)
                }
                Spacer()
                if settings.placement != .right {
                    ResizeEdge(edge: .right).frame(width: 5)
                }
            }
            .padding(.vertical, 20)
            VStack(spacing: 0) {
                Spacer()
                ResizeEdge(edge: .bottom).frame(height: 5)
            }
            .padding(.horizontal, 20)
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @Namespace private var switcherNS

    var body: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 6) {
                brandMark
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
                switcher
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    GlyphButton(glyph: settings.alwaysOnTop ? .pinFilled : .pin, isActive: settings.alwaysOnTop,
                                help: settings.alwaysOnTop ? "Always on top (⇧⌘P)" : "Not pinned (⇧⌘P)") {
                        settings.alwaysOnTop.toggle()
                    }
                    GlyphButton(glyph: .gear, isActive: state.showSettings, help: "Settings (⌘,)") {
                        state.showSettings.toggle()
                    }
                    GlyphButton(glyph: .hide, help: "Hide (⎋)") {
                        state.panel?.hide()
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: Theme.headerHeight)
    }

    private var brandMark: some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 16, height: 16)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 4, height: 9)
                    .offset(x: 3)
            }
            Text("SidePanel")
                .font(Theme.ui(12, .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(width: 104, alignment: .leading)
    }

    private var switcher: some View {
        HStack(spacing: 2) {
            ForEach(PanelSection.allCases) { section in
                let selected = state.section == section
                Button {
                    withAnimation(Theme.snappy) { state.section = section }
                } label: {
                    HStack(spacing: 6) {
                        GlyphView(glyph: section.glyph, size: 13)
                        Text(section.title).font(Theme.ui(11.5, .semibold))
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        if selected {
                            Capsule(style: .continuous)
                                .fill(Theme.surfaceRaised)
                                .overlay(Capsule(style: .continuous).stroke(Theme.hairlineStrong, lineWidth: 0.5))
                                .overlay(alignment: .bottom) {
                                    Capsule().fill(Theme.accentGradient).frame(width: 14, height: 2).offset(y: 1)
                                }
                                .matchedGeometryEffect(id: "section", in: switcherNS)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .help(section == .browser ? "Browser (⌘1)" : "Terminal (⌘2)")
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Theme.surface))
        .overlay(Capsule(style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
    }
}
