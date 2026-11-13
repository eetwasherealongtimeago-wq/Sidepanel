import SidePanelCore
import SwiftUI

/// What a new tab shows: a calm greeting, bookmarks as tiles and recent pages.
struct StartPage: View {
    @EnvironmentObject var browser: BrowserModel

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !browser.library.bookmarks.items.isEmpty {
                    section("Bookmarks") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(browser.library.bookmarks.items.prefix(12)) { bookmark in
                                BookmarkTile(bookmark: bookmark) { browser.open(bookmark.url) }
                            }
                        }
                    }
                }
                let recent = Array(browser.library.history.entries.prefix(6))
                if !recent.isEmpty {
                    section("Recently visited") {
                        VStack(spacing: 2) {
                            ForEach(recent) { entry in
                                RecentRow(entry: entry) { browser.open(entry.url) }
                            }
                        }
                    }
                }
                shortcuts
            }
            .padding(22)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(
            ZStack {
                Theme.canvas
                RadialGradient(colors: [Theme.accent.opacity(0.07), .clear], center: .topLeading, startRadius: 10, endRadius: 420)
                RadialGradient(colors: [Theme.accentAlt.opacity(0.06), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 380)
            }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GlyphView(glyph: .browser, size: 18).foregroundStyle(Theme.accent)
                Text(greeting)
                    .font(Theme.ui(19, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Button {
                browser.requestAddressFocus()
            } label: {
                HStack(spacing: 8) {
                    GlyphView(glyph: .search, size: 12)
                    Text("Search with \(browser.settings.searchEngine.displayName) or type an address")
                        .font(Theme.ui(12))
                    Spacer()
                    Text("⌘L").font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 6)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var shortcuts: some View {
        section("Shortcuts") {
            VStack(alignment: .leading, spacing: 6) {
                shortcut("⌘T", "New tab")
                shortcut("⌘L", "Address bar")
                shortcut("⌘D", "Bookmark this page")
                shortcut("⌘Y", "Library: bookmarks, history, downloads")
                shortcut("⌘2", "Switch to the terminal")
                shortcut("⎋", "Hide SidePanel")
            }
        }
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(Theme.mono(10.5, .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 30)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surfaceRaised))
            Text(label).font(Theme.ui(11.5)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Theme.ui(10, .semibold))
                .kerning(0.8)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }
}

private struct BookmarkTile: View {
    let bookmark: Bookmark
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                LetterAvatar(text: bookmark.url.host ?? bookmark.title, size: 30)
                Text(bookmark.title)
                    .font(Theme.ui(11, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.surfaceRaised : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hovering ? Theme.hairlineStrong : Theme.hairline))
            .offset(y: hovering ? -1 : 0)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.gentle, value: hovering)
        .help(bookmark.url.absoluteString)
    }
}

private struct RecentRow: View {
    let entry: HistoryEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LetterAvatar(text: entry.url.host ?? entry.title, size: 18)
                Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(AddressResolver.displayText(for: entry.url))
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
