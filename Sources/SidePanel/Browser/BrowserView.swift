import SidePanelCore
import SwiftUI

struct BrowserView: View {
    @EnvironmentObject var browser: BrowserModel
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(
                tabs: browser.tabs.map { TabRow(tab: $0).model },
                selectedID: browser.selected?.id,
                onSelect: { id in if let t = browser.tabs.first(where: { $0.id == id }) { browser.select(t) } },
                onClose: { id in if let t = browser.tabs.first(where: { $0.id == id }) { withAnimation(Theme.snappy) { browser.close(t) } } },
                onNew: { withAnimation(Theme.snappy) { _ = browser.newTab(focusAddress: true) } },
                onMove: { browser.moveTab($0, before: $1) }
            )
            .padding(.top, 2)

            if let tab = browser.selected {
                BrowserToolbar(tab: tab)
                    .zIndex(2)
                BrowserContent(tab: tab, isActive: isActive)
                    .zIndex(1)
            }
        }
    }
}

/// Adapts a tab to the shared tab-pill model.
@MainActor
private struct TabRow {
    let tab: BrowserTab
    var model: TabPillModel {
        TabPillModel(id: tab.id, title: tab.displayTitle,
                     avatarSeed: tab.isBlank ? "+" : (tab.url?.host ?? tab.displayTitle),
                     isLoading: tab.isLoading)
    }
}

private struct BrowserToolbar: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var tab: BrowserTab
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 2) {
            GlyphButton(glyph: .back, isEnabled: tab.canGoBack, help: "Back (⌘[)") { tab.webView.goBack() }
            GlyphButton(glyph: .forward, isEnabled: tab.canGoForward, help: "Forward (⌘])") { tab.webView.goForward() }
            GlyphButton(glyph: tab.isLoading ? .stop : .reload, isEnabled: !tab.isBlank,
                        help: tab.isLoading ? "Stop" : "Reload (⌘R)") { tab.reloadOrStop() }

            addressBar
                .padding(.horizontal, 4)

            GlyphButton(glyph: browser.selectedIsBookmarked ? .bookmarkFilled : .bookmark,
                        isActive: browser.selectedIsBookmarked, isEnabled: !tab.isBlank,
                        help: "Bookmark (⌘D)") {
                withAnimation(Theme.snappy) { browser.toggleBookmarkForSelected() }
            }
            ZStack(alignment: .topTrailing) {
                GlyphButton(glyph: .library, isActive: browser.libraryPane != nil, help: "Library (⌘Y)") {
                    withAnimation(Theme.snappy) { browser.openLibrary(browser.downloads.hasUnseenCompletion ? .downloads : .bookmarks) }
                }
                if browser.downloads.activeCount > 0 || browser.downloads.hasUnseenCompletion {
                    Circle()
                        .fill(browser.downloads.activeCount > 0 ? Theme.accentAlt : Theme.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: -4, y: 4)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var addressBar: some View {
        HStack(spacing: 7) {
            GlyphView(glyph: leadingGlyph, size: 11)
                .foregroundStyle(tab.hasSecureContent && !isEditing && !tab.isBlank ? Theme.accent : Theme.textTertiary)
            AddressField(browser: browser, tab: tab, isEditing: $isEditing)
                .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isEditing ? Theme.surfaceRaised : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isEditing ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: isEditing ? 1 : 0.5)
        )
        .overlay(alignment: .bottom) { progressBar }
        .overlay(alignment: .topLeading) {
            if isEditing && !browser.suggestions.isEmpty {
                SuggestionList(browser: browser)
                    .offset(y: 36)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(Theme.gentle, value: isEditing)
        .animation(Theme.gentle, value: browser.suggestions.isEmpty)
    }

    private var leadingGlyph: Glyph {
        if isEditing || tab.isBlank { return .search }
        if tab.url?.isFileURL == true { return .folder }
        return tab.hasSecureContent ? .lock : .globe
    }

    private var progressBar: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.accentGradient)
                .frame(width: geo.size.width * tab.progress, height: 2)
                .opacity(tab.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: tab.progress)
                .animation(.easeOut(duration: 0.4), value: tab.isLoading)
        }
        .frame(height: 2)
        .padding(.horizontal, 6)
        .offset(y: 1)
        .allowsHitTesting(false)
    }
}

private struct BrowserContent: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var tab: BrowserTab
    let isActive: Bool

    var body: some View {
        ZStack {
            HostedView(view: tab.webView, isActive: isActive && !tab.isBlank)
                .opacity(tab.isBlank ? 0 : 1)

            if tab.isBlank {
                StartPage()
                    .transition(.opacity)
            }

            if let error = tab.loadError {
                LoadErrorView(message: error, url: tab.url) { tab.reloadOrStop() }
                    .transition(.opacity)
            }

            if let pane = browser.libraryPane {
                LibraryDrawer(pane: pane)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(Theme.snappy, value: browser.libraryPane)
        .animation(Theme.gentle, value: tab.isBlank)
    }
}

private struct LoadErrorView: View {
    let message: String
    let url: URL?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.danger.opacity(0.12)).frame(width: 64, height: 64)
                GlyphView(glyph: .globe, size: 26).foregroundStyle(Theme.danger)
            }
            Text("This page couldn’t load")
                .font(Theme.ui(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let host = url?.host {
                Text(host).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
            }
            PillButton(title: "Try Again", glyph: .reload, prominent: true, action: retry)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
