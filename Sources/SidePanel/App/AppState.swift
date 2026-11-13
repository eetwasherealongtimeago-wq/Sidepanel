import AppKit
import Combine
import SwiftUI

/// Top-level UI state shared by the panel, the browser and the terminal.
@MainActor
final class AppState: ObservableObject {
    @Published var section: PanelSection {
        didSet {
            guard section != oldValue else { return }
            settings.lastSection = section
            if section == .terminal { terminals.ensureSession() }
            focusActiveSection()
        }
    }
    @Published var showSettings = false
    @Published var hotKeyConflict = false

    let settings: AppSettings
    let browser: BrowserModel
    let terminals: TerminalManager
    weak var panel: PanelController?

    init(settings: AppSettings) {
        self.settings = settings
        self.section = settings.lastSection
        self.browser = BrowserModel(settings: settings)
        self.terminals = TerminalManager(settings: settings)
        if section == .terminal { terminals.ensureSession() }
    }

    /// Puts keyboard focus where the user expects it in the visible section.
    func focusActiveSection() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.panel?.panel else { return }
            switch self.section {
            case .browser:
                self.browser.focusContent(in: window)
            case .terminal:
                self.terminals.ensureSession()
                self.terminals.focusSelected(in: window)
            }
        }
    }

    func prepareForHide() {
        browser.dismissSuggestions()
    }

    /// Closes the innermost transient UI (settings, suggestions, library). Returns true if something closed.
    func dismissTransientUI() -> Bool {
        if showSettings {
            withAnimation(Theme.gentle) { showSettings = false }
            focusActiveSection()
            return true
        }
        if section == .browser && browser.dismissTransient() { return true }
        return false
    }

    func shutdown() {
        terminals.terminateAll()
        browser.library.flush()
    }

    // MARK: Commands

    func newTab() {
        switch section {
        case .browser: browser.newTab(focusAddress: true)
        case .terminal: terminals.newSession()
        }
        focusActiveSection()
    }

    func closeTab() {
        switch section {
        case .browser: browser.closeSelected()
        case .terminal: terminals.closeSelected()
        }
        focusActiveSection()
    }

    func cycleTab(_ delta: Int) {
        switch section {
        case .browser: browser.cycle(delta)
        case .terminal: terminals.cycle(delta)
        }
        focusActiveSection()
    }

    func selectTab(number: Int) {
        switch section {
        case .browser: browser.select(number: number)
        case .terminal: terminals.select(number: number)
        }
        focusActiveSection()
    }

    func zoom(_ direction: Int) {
        switch section {
        case .browser: browser.zoom(direction)
        case .terminal: terminals.zoom(direction)
        }
    }
}

// MARK: - Menu command routing (the window delegate sits in the responder chain)

extension PanelController: PanelCommands {
    @objc func newTab(_ sender: Any?) { state.newTab() }
    @objc func closeTab(_ sender: Any?) { state.closeTab() }
    @objc func nextTab(_ sender: Any?) { state.cycleTab(1) }
    @objc func previousTab(_ sender: Any?) { state.cycleTab(-1) }
    @objc func selectTabByNumber(_ sender: Any?) {
        if let item = sender as? NSMenuItem { state.selectTab(number: item.tag) }
    }
    @objc func showBrowser(_ sender: Any?) { withAnimation(Theme.snappy) { state.section = .browser } }
    @objc func showTerminal(_ sender: Any?) { withAnimation(Theme.snappy) { state.section = .terminal } }
    @objc func focusAddressBar(_ sender: Any?) {
        if state.section != .browser { state.section = .browser }
        state.browser.requestAddressFocus()
    }
    @objc func reloadPage(_ sender: Any?) { if state.section == .browser { state.browser.selected?.reloadOrStop() } }
    @objc func goBack(_ sender: Any?) { if state.section == .browser { state.browser.selected?.webView.goBack() } }
    @objc func goForward(_ sender: Any?) { if state.section == .browser { state.browser.selected?.webView.goForward() } }
    @objc func toggleBookmark(_ sender: Any?) { if state.section == .browser { state.browser.toggleBookmarkForSelected() } }
    @objc func showLibrary(_ sender: Any?) {
        state.section = .browser
        state.browser.openLibrary(.history)
    }
    @objc func showDownloads(_ sender: Any?) {
        state.section = .browser
        state.browser.openLibrary(.downloads)
    }
    @objc func showSettings(_ sender: Any?) { withAnimation(Theme.gentle) { state.showSettings.toggle() } }
    @objc func zoomIn(_ sender: Any?) { state.zoom(1) }
    @objc func zoomOut(_ sender: Any?) { state.zoom(-1) }
    @objc func zoomReset(_ sender: Any?) { state.zoom(0) }
    @objc func clearTerminal(_ sender: Any?) { if state.section == .terminal { state.terminals.selected?.clear() } }
    @objc func hidePanel(_ sender: Any?) { hide() }
    @objc func togglePinned(_ sender: Any?) { state.settings.alwaysOnTop.toggle() }
}
