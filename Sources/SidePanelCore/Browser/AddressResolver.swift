import Foundation

public enum SearchEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case duckDuckGo, google, bing, startpage, ecosia, kagi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .startpage: return "Startpage"
        case .ecosia: return "Ecosia"
        case .kagi: return "Kagi"
        }
    }

    private var template: String {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/?q=%s"
        case .google: return "https://www.google.com/search?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .startpage: return "https://www.startpage.com/sp/search?query=%s"
        case .ecosia: return "https://www.ecosia.org/search?q=%s"
        case .kagi: return "https://kagi.com/search?q=%s"
        }
    }

    public func searchURL(for query: String) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))!
    }
}

/// Decides whether what the user typed in the address bar is a URL, a host
/// name, a local path or a search query.
public enum AddressResolver {
    static let directSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "ftp", "view-source"]

    public static func resolve(_ rawInput: String, engine: SearchEngine,
                               homeDirectory: String = NSHomeDirectory()) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        // Explicit scheme.
        if let colon = input.firstIndex(of: ":") {
            let scheme = input[..<colon].lowercased()
            if directSchemes.contains(scheme) && !input.contains(" ") {
                if let url = URL(string: input) { return url }
                if let encoded = input.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                   let url = URL(string: encoded) { return url }
            }
        }

        if input.contains(where: { $0 == " " || $0 == "\t" }) {
            return engine.searchURL(for: input)
        }

        // Local paths.
        if input.hasPrefix("/") || input.hasPrefix("~/") {
            let path = input.hasPrefix("~/") ? homeDirectory + String(input.dropFirst(1)) : input
            return URL(fileURLWithPath: path)
        }

        if let host = hostCandidate(input) {
            let insecure = host == "localhost" || isIPAddress(host) || host.hasSuffix(".local")
                || host.hasSuffix(".test") || host.hasSuffix(".internal")
            let scheme = insecure ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(input)") { return url }
        }

        return engine.searchURL(for: input)
    }

    /// Returns the host portion if `input` looks like "host[:port][/path]".
    static func hostCandidate(_ input: String) -> String? {
        var authority = input
        if let i = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(authority[..<i])
        }
        if authority.contains("@") { return nil }
        var host = authority
        if host.hasPrefix("[") {
            // [IPv6]:port
            guard let close = host.firstIndex(of: "]") else { return nil }
            let inner = String(host[host.index(after: host.startIndex)..<close])
            return inner.contains(":") ? inner : nil
        }
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            host = String(host[..<colon])
        }
        host = host.lowercased()
        if host == "localhost" || isIPAddress(host) { return host }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        for label in labels {
            guard label.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  label.first != "-", label.last != "-" else { return nil }
        }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) || tld.hasPrefix("xn--") else {
            return nil
        }
        return host
    }

    static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 && parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            return true
        }
        return host.contains(":") && host.allSatisfy { $0.isHexDigit || $0 == ":" }
    }

    /// Compact text shown in the address bar when it isn't being edited.
    public static func displayText(for url: URL?) -> String {
        guard let url else { return "" }
        if url.isFileURL { return url.path }
        guard let host = url.host else { return url.absoluteString }
        var shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = url.port { shown += ":\(port)" }
        let path = url.path
        if !path.isEmpty && path != "/" { shown += path }
        return shown
    }

    /// Key used to treat "https://a.com/x/" and "https://a.com/x#top" as the same page.
    public static func normalizedKey(for url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        comps.fragment = nil
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        var s = comps.string ?? url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
