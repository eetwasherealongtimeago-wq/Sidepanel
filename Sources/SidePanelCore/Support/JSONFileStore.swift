import Foundation

/// Persists a single Codable value as JSON, writing atomically and off the caller's thread.
public final class JSONFileStore<Value: Codable> {
    public let url: URL
    private let queue: DispatchQueue
    private var pending: DispatchWorkItem?
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        self.queue = DispatchQueue(label: "sidepanel.store.\(url.lastPathComponent)", qos: .utility)
    }

    /// `~/Library/Application Support/SidePanel/<name>` (created on demand).
    public static func applicationSupportURL(fileName: String, appFolder: String = "SidePanel") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(appFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    /// Saves after `delay` seconds, coalescing rapid successive calls.
    public func save(_ value: Value, delay: TimeInterval = 0.5) {
        let item = DispatchWorkItem { [url] in
            JSONFileStore.write(value, to: url)
        }
        lock.lock()
        pending?.cancel()
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Writes immediately on the calling thread (used at shutdown and in tests).
    public func saveNow(_ value: Value) {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
        JSONFileStore.write(value, to: url)
    }

    private static func write(_ value: Value, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
