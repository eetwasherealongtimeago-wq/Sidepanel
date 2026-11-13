import Foundation

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var created: Date

    public init(id: UUID = UUID(), title: String, url: URL, created: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.created = created
    }
}

public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var lastVisited: Date
    public var visitCount: Int

    public init(id: UUID = UUID(), title: String, url: URL, lastVisited: Date = Date(), visitCount: Int = 1) {
        self.id = id
        self.title = title
        self.url = url
        self.lastVisited = lastVisited
        self.visitCount = visitCount
    }
}

public struct BookmarkList: Codable, Equatable, Sendable {
    public private(set) var items: [Bookmark] = []

    public init(items: [Bookmark] = []) { self.items = items }

    public func contains(_ url: URL) -> Bool {
        let key = AddressResolver.normalizedKey(for: url)
        return items.contains { AddressResolver.normalizedKey(for: $0.url) == key }
    }

    public mutating func add(title: String, url: URL) {
        guard !contains(url) else { return }
        items.insert(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url), at: 0)
    }

    public mutating func remove(_ url: URL) {
        let key = AddressResolver.normalizedKey(for: url)
        items.removeAll { AddressResolver.normalizedKey(for: $0.url) == key }
    }

    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func rename(id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { items[$0] }
        var remaining = items
        for i in source.sorted(by: >) { remaining.remove(at: i) }
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        items = remaining
    }

    /// Adds the bookmark if absent, removes it otherwise. Returns the new state.
    @discardableResult
    public mutating func toggle(title: String, url: URL) -> Bool {
        if contains(url) { remove(url); return false }
        add(title: title, url: url)
        return true
    }
}

public struct BrowsingHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [HistoryEntry] = []   // most recent first
    public var limit: Int

    public init(entries: [HistoryEntry] = [], limit: Int = 5_000) {
        self.entries = entries
        self.limit = limit
    }

    public mutating func record(url: URL, title: String, at date: Date = Date()) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return }
        let key = AddressResolver.normalizedKey(for: url)
        if let i = entries.firstIndex(where: { AddressResolver.normalizedKey(for: $0.url) == key }) {
            var e = entries.remove(at: i)
            e.lastVisited = date
            e.visitCount += 1
            if !title.isEmpty { e.title = title }
            e.url = url
            entries.insert(e, at: 0)
        } else {
            entries.insert(HistoryEntry(title: title, url: url, lastVisited: date), at: 0)
            if entries.count > limit { entries.removeLast(entries.count - limit) }
        }
    }

    public mutating func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty else { return }
        let key = AddressResolver.normalizedKey(for: url)
        if let i = entries.firstIndex(where: { AddressResolver.normalizedKey(for: $0.url) == key }) {
            entries[i].title = title
        }
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func clear(since date: Date? = nil) {
        if let date { entries.removeAll { $0.lastVisited >= date } } else { entries.removeAll() }
    }

    public func search(_ query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
    }
}

public struct AddressSuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case bookmark, history, search }
    public var id: String { kind == .search ? "search:\(title)" : url.absoluteString }
    public var kind: Kind
    public var title: String
    public var url: URL
}

public enum SuggestionEngine {
    /// Ranks bookmarks and history against what the user is typing.
    public static func suggestions(for input: String, bookmarks: BookmarkList, history: BrowsingHistory,
                                   engine: SearchEngine, limit: Int = 6, now: Date = Date()) -> [AddressSuggestion] {
        let q = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }

        func stripped(_ url: URL) -> String {
            var s = url.absoluteString.lowercased()
            for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
            if s.hasPrefix("www.") { s.removeFirst(4) }
            return s
        }

        func score(title: String, url: URL, visits: Int, last: Date?, bonus: Double) -> Double? {
            let u = stripped(url)
            let t = title.lowercased()
            var s: Double
            if u.hasPrefix(q) { s = 100 }
            else if t.hasPrefix(q) { s = 70 }
            else if u.contains(q) { s = 40 }
            else if t.contains(q) { s = 30 }
            else { return nil }
            s += min(Double(visits), 50) * 0.8
            if let last {
                let days = now.timeIntervalSince(last) / 86_400
                s += max(0, 20 - days)
            }
            return s + bonus
        }

        var scored: [String: (Double, AddressSuggestion)] = [:]
        for b in bookmarks.items {
            if let s = score(title: b.title, url: b.url, visits: 0, last: nil, bonus: 25) {
                let key = AddressResolver.normalizedKey(for: b.url)
                scored[key] = (s, AddressSuggestion(kind: .bookmark, title: b.title, url: b.url))
            }
        }
        for e in history.entries.prefix(2_000) {
            guard let s = score(title: e.title, url: e.url, visits: e.visitCount, last: e.lastVisited, bonus: 0) else { continue }
            let key = AddressResolver.normalizedKey(for: e.url)
            if let existing = scored[key] {
                scored[key] = (existing.0 + s * 0.5, existing.1)
            } else {
                scored[key] = (s, AddressSuggestion(kind: .history, title: e.title, url: e.url))
            }
        }
        var result = scored.values.sorted { $0.0 > $1.0 }.prefix(max(limit - 1, 0)).map(\.1)
        result.append(AddressSuggestion(kind: .search, title: input, url: engine.searchURL(for: input)))
        return result
    }
}
