import AppKit
import Combine
import SidePanelCore
import WebKit

enum LibraryPane: String, CaseIterable, Identifiable {
    case bookmarks, history, downloads
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var glyph: Glyph {
        switch self {
        case .bookmarks: return .bookmark
        case .history: return .history
        case .downloads: return .download
        }
    }
}

/// All browser state: tabs, the shared web configuration, library and downloads.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published var libraryPane: LibraryPane?
    @Published var suggestions: [AddressSuggestion] = []
    @Published var highlightedSuggestion: Int = 0
    /// Bumped to ask the address field to take keyboard focus.
    @Published private(set) var addressFocusRequest = 0

    let settings: AppSettings
    let library = LibraryModel()
    let downloads = DownloadManager()
    let configuration: WKWebViewConfiguration
    private var cancellables = Set<AnyCancellable>()
    private var tabSubscriptions: [UUID: AnyCancellable] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Identify as a modern WebKit browser so sites serve their full experience.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15 SidePanel/1.0"
        self.configuration = config

        library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        downloads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        newTab(focusAddress: false)
    }

    var selected: BrowserTab? {
        tabs.first { $0.id == selectedID } ?? tabs.first
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL? = nil, focusAddress: Bool = false, select: Bool = true,
                configuration custom: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: custom ?? configuration, owner: self)
        tab.webView.pageZoom = settings.browserZoom
        // Re-render the tab strip and toolbar when what they show changes.
        tabSubscriptions[tab.id] = Publishers.Merge4(
            tab.$title.map { _ in () }, tab.$isLoading.removeDuplicates().map { _ in () },
            tab.$isBlank.removeDuplicates().map { _ in () }, tab.$url.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.objectWillChange.send() }
        if let index = tabs.firstIndex(where: { $0.id == selectedID }), custom != nil || url != nil {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select { selectedID = tab.id }
        if let url {
            tab.load(url)
        } else if custom == nil, let home = homeURL {
            tab.load(home)
        }
        if focusAddress && url == nil { requestAddressFocus() }
        return tab
    }

    private var homeURL: URL? {
        let h = settings.homePage.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        return AddressResolver.resolve(h, engine: settings.searchEngine)
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.tearDown()
        tabSubscriptions[tab.id] = nil
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab(focusAddress: true)
        } else if selectedID == tab.id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelected() {
        if let tab = selected { close(tab) }
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
        dismissSuggestions()
    }

    func cycle(_ delta: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selected?.id }), !tabs.isEmpty else { return }
        selectedID = tabs[(i + delta + tabs.count) % tabs.count].id
    }

    func select(number: Int) {
        guard !tabs.isEmpty else { return }
        let i = number >= 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1)
        selectedID = tabs[i].id
    }

    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let to = tabs.firstIndex(where: { $0.id == target }) ?? tabs.count
        tabs.insert(tab, at: to)
    }

    // MARK: Navigation

    func navigate(to input: String) {
        guard let url = AddressResolver.resolve(input, engine: settings.searchEngine) else { return }
        open(url)
    }

    func open(_ url: URL, inNewTab: Bool = false) {
        dismissSuggestions()
        libraryPane = nil
        if inNewTab || selected == nil {
            newTab(url: url)
        } else {
            selected?.load(url)
        }
        if let window = selected?.webView.window {
            window.makeFirstResponder(selected?.webView)
        }
    }

    func requestAddressFocus() {
        addressFocusRequest += 1
    }

    func focusContent(in window: NSWindow) {
        guard let tab = selected else { return }
        if tab.isBlank {
            requestAddressFocus()
        } else {
            window.makeFirstResponder(tab.webView)
        }
    }

    // MARK: Suggestions

    func updateSuggestions(for text: String) {
        suggestions = SuggestionEngine.suggestions(for: text, bookmarks: library.bookmarks,
                                                   history: library.history, engine: settings.searchEngine)
        highlightedSuggestion = -1
    }

    func dismissSuggestions() {
        if !suggestions.isEmpty { suggestions = [] }
    }

    /// Escape handling for browser-local UI. Returns true if something closed.
    func dismissTransient() -> Bool {
        if !suggestions.isEmpty {
            dismissSuggestions()
            return true
        }
        if libraryPane != nil {
            libraryPane = nil
            return true
        }
        return false
    }

    // MARK: Library

    func openLibrary(_ pane: LibraryPane) {
        libraryPane = libraryPane == pane ? nil : pane
    }

    func toggleBookmarkForSelected() {
        guard let tab = selected, let url = tab.url, !tab.isBlank else { return }
        library.toggleBookmark(title: tab.title, url: url)
    }

    var selectedIsBookmarked: Bool {
        guard let url = selected?.url, selected?.isBlank == false else { return false }
        return library.bookmarks.contains(url)
    }

    // MARK: Zoom

    func zoom(_ direction: Int) {
        let steps: [Double] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
        let current = selected?.webView.pageZoom ?? 1
        var next = 1.0
        if direction > 0 { next = steps.first { $0 > current + 0.001 } ?? steps.last! }
        if direction < 0 { next = steps.last { $0 < current - 0.001 } ?? steps.first! }
        settings.browserZoom = next
        for tab in tabs { tab.webView.pageZoom = next }
    }

    // MARK: Called by tabs

    func recordVisit(url: URL, title: String) {
        library.recordVisit(url: url, title: title)
    }

    func tabRequestedClose(_ tab: BrowserTab) {
        close(tab)
    }
}

/// One browser tab, wrapping a WKWebView and mirroring its state for SwiftUI.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    weak var owner: BrowserModel?

    @Published var title: String = "New Tab"
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var hasSecureContent = false
    /// True until the tab loads its first page; the start page is shown instead.
    @Published var isBlank = true
    @Published var loadError: String?
    private var failedURL: URL?
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, owner: BrowserModel) {
        self.owner = owner
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = NSColor(hex: 0x0B0C10)

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.syncTitle(wv.title) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let u = wv.url, u.absoluteString != "about:blank" {
                        self.url = u
                        self.isBlank = false
                    }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.isLoading = wv.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.hasSecureContent = wv.hasOnlySecureContent }
            },
        ]
    }

    private func syncTitle(_ newTitle: String?) {
        let t = (newTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            title = t
            if let url { owner?.library.updateTitle(t, for: url) }
        } else if let host = url?.host {
            title = host
        }
    }

    func load(_ url: URL) {
        isBlank = false
        loadError = nil
        self.url = url
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else if loadError != nil, let failed = failedURL {
            load(failed)
        } else if !isBlank {
            webView.reload()
        }
    }

    func goHomeToStartPage() {
        webView.stopLoading()
        isBlank = true
        loadError = nil
        url = nil
        title = "New Tab"
    }

    func tearDown() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    var displayTitle: String {
        isBlank ? "New Tab" : (title.isEmpty ? (url?.host ?? "Loading…") : title)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    private static let webSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "javascript"]

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if !BrowserTab.webSchemes.contains(scheme) {
            // mailto:, tel:, facetime:, app deep links… hand over to the system.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel, preferences)
            return
        }
        // ⌘-click / middle-click opens a background tab.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2 {
            owner?.newTab(url: url, select: navigationAction.modifierFlags.contains(.shift))
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        owner?.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        owner?.downloads.track(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isBlank = false
        loadError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            owner?.recordVisit(url: url, title: webView.title ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error, for: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error, for: webView)
    }

    private func handle(_ error: Error, for webView: WKWebView) {
        let ns = error as NSError
        // Cancelled navigations and "frame load interrupted" (downloads, policy changes) aren't failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        failedURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? url
        loadError = ns.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open(): open as a new tab sharing the required configuration.
        guard let owner else { return nil }
        let tab = owner.newTab(select: true, configuration: configuration)
        tab.isBlank = false
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.tabRequestedClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = makeAlert(message: prompt, frame: frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
        alert.window.initialFirstResponder = field
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    private func makeAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
