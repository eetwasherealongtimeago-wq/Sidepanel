import SidePanelCore
import SwiftUI

/// Slide-over drawer with bookmarks, history and downloads.
struct LibraryDrawer: View {
    @EnvironmentObject var browser: BrowserModel
    let pane: LibraryPane
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            // Clicking the dimmed area closes the drawer.
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(Theme.snappy) { browser.libraryPane = nil } }

            VStack(spacing: 0) {
                header
                if pane != .downloads {
                    searchField
                }
                Divider().overlay(Theme.hairline)
                content
            }
            .frame(width: 330)
            .background(Theme.surface)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.hairlineStrong).frame(width: 0.5) }
        }
        .onAppear { if pane == .downloads { browser.downloads.hasUnseenCompletion = false } }
        .onChange(of: pane) { newPane in
            query = ""
            if newPane == .downloads { browser.downloads.hasUnseenCompletion = false }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(LibraryPane.allCases) { p in
                Button {
                    withAnimation(Theme.snappy) { browser.libraryPane = p }
                } label: {
                    HStack(spacing: 5) {
                        GlyphView(glyph: p.glyph, size: 11)
                        Text(p.title).font(Theme.ui(11.5, .medium))
                    }
                    .foregroundStyle(p == pane ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p == pane ? Theme.surfaceRaised : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            GlyphButton(glyph: .close, size: 24, iconSize: 11, help: "Close") {
                withAnimation(Theme.snappy) { browser.libraryPane = nil }
            }
        }
        .padding(8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            GlyphView(glyph: .search, size: 11).foregroundStyle(Theme.textTertiary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.canvas))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .bookmarks: bookmarks
        case .history: history
        case .downloads: downloads
        }
    }

    // MARK: Bookmarks

    private var bookmarks: some View {
        let q = query.lowercased()
        let items = browser.library.bookmarks.items.filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
        return Group {
            if items.isEmpty {
                EmptyLibrary(glyph: .bookmark, text: q.isEmpty ? "No bookmarks yet.\nPress ⌘D on any page." : "No matches.")
            } else {
                List {
                    ForEach(items) { b in
                        LibraryRow(title: b.title, subtitle: AddressResolver.displayText(for: b.url), seed: b.url.host ?? b.title,
                                   onOpen: { browser.open(b.url) },
                                   onOpenNewTab: { browser.open(b.url, inNewTab: true) },
                                   onDelete: { browser.library.removeBookmark(b.id) })
                    }
                    .onMove { from, to in
                        if q.isEmpty { browser.library.moveBookmarks(from: from, to: to) }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: History

    private var history: some View {
        let entries = browser.library.history.search(query)
        let groups = Dictionary(grouping: entries.prefix(800)) { Calendar.current.startOfDay(for: $0.lastVisited) }
        let days = groups.keys.sorted(by: >)
        return VStack(spacing: 0) {
            if entries.isEmpty {
                EmptyLibrary(glyph: .history, text: query.isEmpty ? "Pages you visit appear here." : "No matches.")
            } else {
                List {
                    ForEach(days, id: \.self) { day in
                        Section {
                            ForEach(groups[day] ?? []) { e in
                                LibraryRow(title: e.title.isEmpty ? e.url.absoluteString : e.title,
                                           subtitle: AddressResolver.displayText(for: e.url),
                                           seed: e.url.host ?? e.title,
                                           trailing: e.lastVisited.formatted(date: .omitted, time: .shortened),
                                           onOpen: { browser.open(e.url) },
                                           onOpenNewTab: { browser.open(e.url, inNewTab: true) },
                                           onDelete: { browser.library.removeHistoryEntry(e.id) })
                                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text(dayTitle(day))
                                .font(Theme.ui(10, .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            HStack {
                Spacer()
                Menu {
                    Button("Last hour") { browser.library.clearHistory(since: Date().addingTimeInterval(-3600)) }
                    Button("Today") { browser.library.clearHistory(since: Calendar.current.startOfDay(for: Date())) }
                    Button("All history") { browser.library.clearHistory() }
                } label: {
                    Text("Clear History…").font(Theme.ui(11, .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(8)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(date: .abbreviated, time: .omitted).uppercased()
    }

    // MARK: Downloads

    private var downloads: some View {
        VStack(spacing: 0) {
            if browser.downloads.items.isEmpty {
                EmptyLibrary(glyph: .download, text: "Downloads are saved to your Downloads folder.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(browser.downloads.items) { item in
                            DownloadRow(item: item, manager: browser.downloads)
                        }
                    }
                    .padding(8)
                }
                HStack {
                    Spacer()
                    Button("Clear Finished") { browser.downloads.clearFinished() }
                        .buttonStyle(.plain)
                        .font(Theme.ui(11, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(8)
            }
        }
    }
}

private struct LibraryRow: View {
    let title: String
    let subtitle: String
    let seed: String
    var trailing: String? = nil
    let onOpen: () -> Void
    let onOpenNewTab: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            LetterAvatar(text: seed, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.ui(12, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(Theme.ui(10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: onDelete) {
                    GlyphView(glyph: .trash, size: 11).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            } else if let trailing {
                Text(trailing).font(Theme.ui(10)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.surfaceRaised : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Open in New Tab", action: onOpenNewTab)
            Divider()
            Button("Remove", action: onDelete)
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let manager: DownloadManager

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceRaised).frame(width: 32, height: 32)
                GlyphView(glyph: .download, size: 14).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName).font(Theme.ui(12, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if item.isActive {
                    ProgressBar(value: item.progress)
                }
                Text(status).font(Theme.ui(10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.isActive {
                GlyphButton(glyph: .close, size: 22, iconSize: 10, help: "Cancel") { manager.cancel(item) }
            } else if item.state == .finished {
                GlyphButton(glyph: .open, size: 22, iconSize: 11, help: "Open") { manager.open(item) }
                GlyphButton(glyph: .folder, size: 22, iconSize: 11, help: "Show in Finder") { manager.reveal(item) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas.opacity(0.6)))
    }

    private var tint: Color {
        switch item.state {
        case .finished: return Theme.accent
        case .failed: return Theme.danger
        case .cancelled: return Theme.textTertiary
        default: return Theme.accentAlt
        }
    }

    private var status: String {
        let fmt = ByteCountFormatter()
        switch item.state {
        case .preparing: return "Starting…"
        case .downloading:
            let got = fmt.string(fromByteCount: item.receivedBytes)
            if item.expectedBytes > 0 { return "\(got) of \(fmt.string(fromByteCount: item.expectedBytes))" }
            return got
        case .finished: return item.expectedBytes > 0 ? "Done · \(fmt.string(fromByteCount: item.expectedBytes))" : "Done"
        case .failed(let message): return "Failed · \(message)"
        case .cancelled: return "Cancelled"
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceHover)
                Capsule().fill(Theme.accentGradient).frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

private struct EmptyLibrary: View {
    let glyph: Glyph
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            GlyphView(glyph: glyph, size: 22).foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
