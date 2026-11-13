import Foundation
import SidePanelCore

/// Bookmarks and history, persisted as JSON in Application Support.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var bookmarks: BookmarkList
    @Published private(set) var history: BrowsingHistory

    private let bookmarkStore = JSONFileStore<BookmarkList>(url: JSONFileStore<BookmarkList>.applicationSupportURL(fileName: "Bookmarks.json"))
    private let historyStore = JSONFileStore<BrowsingHistory>(url: JSONFileStore<BrowsingHistory>.applicationSupportURL(fileName: "History.json"))

    init() {
        bookmarks = bookmarkStore.load() ?? LibraryModel.starterBookmarks
        history = historyStore.load() ?? BrowsingHistory()
    }

    private static var starterBookmarks: BookmarkList {
        var list = BookmarkList()
        let starters: [(String, String)] = [
            ("Wikipedia", "https://www.wikipedia.org"),
            ("Hacker News", "https://news.ycombinator.com"),
            ("MDN Web Docs", "https://developer.mozilla.org"),
            ("Swift.org", "https://www.swift.org"),
        ]
        for (title, url) in starters.reversed() {
            if let u = URL(string: url) { list.add(title: title, url: u) }
        }
        return list
    }

    // MARK: Bookmarks

    func toggleBookmark(title: String, url: URL) {
        bookmarks.toggle(title: title, url: url)
        bookmarkStore.save(bookmarks)
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.remove(id: id)
        bookmarkStore.save(bookmarks)
    }

    func renameBookmark(_ id: UUID, to title: String) {
        bookmarks.rename(id: id, to: title)
        bookmarkStore.save(bookmarks)
    }

    func moveBookmarks(from source: IndexSet, to destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        bookmarkStore.save(bookmarks)
    }

    // MARK: History

    func recordVisit(url: URL, title: String) {
        history.record(url: url, title: title)
        historyStore.save(history, delay: 2)
    }

    func updateTitle(_ title: String, for url: URL) {
        history.updateTitle(title, for: url)
        historyStore.save(history, delay: 2)
    }

    func removeHistoryEntry(_ id: UUID) {
        history.remove(id: id)
        historyStore.save(history)
    }

    func clearHistory(since date: Date? = nil) {
        history.clear(since: date)
        historyStore.save(history, delay: 0)
    }

    func flush() {
        bookmarkStore.saveNow(bookmarks)
        historyStore.saveNow(history)
    }
}
