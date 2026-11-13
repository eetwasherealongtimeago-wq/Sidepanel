import XCTest
@testable import SidePanelCore

final class AddressResolverTests: XCTestCase {
    private func r(_ s: String) -> String? {
        AddressResolver.resolve(s, engine: .duckDuckGo, homeDirectory: "/Users/me")?.absoluteString
    }

    func testURLsWithScheme() {
        XCTAssertEqual(r("https://example.com/a?b=c"), "https://example.com/a?b=c")
        XCTAssertEqual(r("about:blank"), "about:blank")
        XCTAssertEqual(r("file:///tmp/x.html"), "file:///tmp/x.html")
    }

    func testBareHosts() {
        XCTAssertEqual(r("example.com"), "https://example.com")
        XCTAssertEqual(r("sub.example.co.uk/path?q=1"), "https://sub.example.co.uk/path?q=1")
        XCTAssertEqual(r("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(r("192.168.1.10/admin"), "http://192.168.1.10/admin")
        XCTAssertEqual(r("printer.local"), "http://printer.local")
    }

    func testSearches() {
        XCTAssertEqual(r("swift concurrency"), "https://duckduckgo.com/?q=swift%20concurrency")
        XCTAssertEqual(r("hello"), "https://duckduckgo.com/?q=hello")
        XCTAssertEqual(r("c++ & rust"), "https://duckduckgo.com/?q=c%2B%2B%20%26%20rust")
        XCTAssertEqual(r("1.5"), "https://duckduckgo.com/?q=1.5")
        XCTAssertNil(r("   "))
    }

    func testLocalPaths() {
        XCTAssertEqual(r("~/Sites/index.html"), "file:///Users/me/Sites/index.html")
        XCTAssertEqual(r("/tmp/page.html"), "file:///tmp/page.html")
    }

    func testOtherEngines() {
        XCTAssertEqual(SearchEngine.google.searchURL(for: "a b").absoluteString, "https://www.google.com/search?q=a%20b")
    }

    func testDisplayText() {
        XCTAssertEqual(AddressResolver.displayText(for: URL(string: "https://www.apple.com/")), "apple.com")
        XCTAssertEqual(AddressResolver.displayText(for: URL(string: "http://localhost:8080/docs")), "localhost:8080/docs")
    }

    func testNormalizedKey() {
        let a = URL(string: "https://Example.com/x/#top")!
        let b = URL(string: "https://example.com/x")!
        XCTAssertEqual(AddressResolver.normalizedKey(for: a), AddressResolver.normalizedKey(for: b))
    }
}

final class LibraryTests: XCTestCase {
    func testBookmarkToggle() {
        var list = BookmarkList()
        let url = URL(string: "https://example.com/")!
        XCTAssertTrue(list.toggle(title: "Example", url: url))
        XCTAssertTrue(list.contains(URL(string: "https://example.com")!))
        XCTAssertFalse(list.toggle(title: "Example", url: url))
        XCTAssertTrue(list.items.isEmpty)
    }

    func testBookmarkMove() {
        var list = BookmarkList()
        for n in ["c", "b", "a"] { list.add(title: n, url: URL(string: "https://\(n).com")!) }
        XCTAssertEqual(list.items.map(\.title), ["a", "b", "c"])
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(list.items.map(\.title), ["b", "c", "a"])
    }

    func testHistoryDeduplicatesAndOrders() {
        var h = BrowsingHistory(limit: 3)
        let t0 = Date(timeIntervalSince1970: 0)
        h.record(url: URL(string: "https://a.com")!, title: "A", at: t0)
        h.record(url: URL(string: "https://b.com")!, title: "B", at: t0)
        h.record(url: URL(string: "https://a.com/")!, title: "", at: t0)
        XCTAssertEqual(h.entries.map(\.title), ["A", "B"])
        XCTAssertEqual(h.entries[0].visitCount, 2)
        h.record(url: URL(string: "https://c.com")!, title: "C")
        h.record(url: URL(string: "https://d.com")!, title: "D")
        XCTAssertEqual(h.entries.count, 3)
        h.record(url: URL(string: "about:blank")!, title: "x")
        XCTAssertEqual(h.entries.count, 3)
        XCTAssertEqual(h.search("c.com").map(\.title), ["C"])
    }

    func testSuggestionsRankPrefixMatchesFirst() {
        var h = BrowsingHistory()
        h.record(url: URL(string: "https://news.example.com")!, title: "Daily News")
        h.record(url: URL(string: "https://github.com")!, title: "GitHub")
        var b = BookmarkList()
        b.add(title: "Gist", url: URL(string: "https://gist.github.com")!)
        let s = SuggestionEngine.suggestions(for: "gi", bookmarks: b, history: h, engine: .duckDuckGo)
        XCTAssertEqual(s.first?.title, "Gist")
        XCTAssertEqual(s.dropFirst().first?.title, "GitHub")
        XCTAssertEqual(s.last?.kind, .search)
    }

    func testJSONStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore<BookmarkList>(url: dir.appendingPathComponent("b.json"))
        var list = BookmarkList()
        list.add(title: "X", url: URL(string: "https://x.org")!)
        store.saveNow(list)
        XCTAssertEqual(store.load()?.items.map(\.title), ["X"])
        try? FileManager.default.removeItem(at: dir)
    }
}
