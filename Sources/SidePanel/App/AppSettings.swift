import AppKit
import Combine
import ServiceManagement
import SidePanelCore

enum PanelSection: String, CaseIterable, Identifiable {
    case browser, terminal
    var id: String { rawValue }
    var title: String { self == .browser ? "Browser" : "Terminal" }
    var glyph: Glyph { self == .browser ? .browser : .terminal }
}

enum PanelPlacement: String, CaseIterable, Identifiable {
    case right, left, center, free
    var id: String { rawValue }
    var title: String {
        switch self {
        case .right: return "Right edge"
        case .left: return "Left edge"
        case .center: return "Top center"
        case .free: return "Where I leave it"
        }
    }
}

/// User preferences, persisted to UserDefaults on every change.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Activation
    @Published var hotKey: HotKey { didSet { saveHotKey() } }
    @Published var edgeActivation: Bool { didSet { d.set(edgeActivation, forKey: K.edge) } }
    @Published var edgeDelay: Double { didSet { d.set(edgeDelay, forKey: K.edgeDelay) } }

    // Panel
    @Published var placement: PanelPlacement { didSet { d.set(placement.rawValue, forKey: K.placement) } }
    @Published var panelWidth: Double { didSet { d.set(panelWidth, forKey: K.width) } }
    @Published var panelHeightFraction: Double { didSet { d.set(panelHeightFraction, forKey: K.height) } }
    @Published var freeFrame: NSRect? { didSet { d.set(freeFrame.map { NSStringFromRect($0) }, forKey: K.freeFrame) } }
    @Published var alwaysOnTop: Bool { didSet { d.set(alwaysOnTop, forKey: K.onTop) } }
    @Published var hideWhenInactive: Bool { didSet { d.set(hideWhenInactive, forKey: K.hideInactive) } }
    @Published var escapeHides: Bool { didSet { d.set(escapeHides, forKey: K.escape) } }
    @Published var animations: Bool { didSet { d.set(animations, forKey: K.animations) } }
    @Published var lastSection: PanelSection { didSet { d.set(lastSection.rawValue, forKey: K.section) } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: K.menuIcon) } }

    // Browser
    @Published var searchEngine: SearchEngine { didSet { d.set(searchEngine.rawValue, forKey: K.engine) } }
    @Published var homePage: String { didSet { d.set(homePage, forKey: K.home) } }
    @Published var browserZoom: Double { didSet { d.set(browserZoom, forKey: K.zoom) } }

    // Terminal
    @Published var terminalFontSize: Double { didSet { d.set(terminalFontSize, forKey: K.fontSize) } }
    @Published var optionAsMeta: Bool { didSet { d.set(optionAsMeta, forKey: K.meta) } }
    @Published var scrollbackLines: Int { didSet { d.set(scrollbackLines, forKey: K.scrollback) } }
    @Published var shellPath: String { didSet { d.set(shellPath, forKey: K.shell) } }
    @Published var terminalEscapeHides: Bool { didSet { d.set(terminalEscapeHides, forKey: K.termEscape) } }
    @Published var cursorBlink: Bool { didSet { d.set(cursorBlink, forKey: K.blink) } }

    private enum K {
        static let hotKeyCode = "hotKey.code", hotKeyMods = "hotKey.mods"
        static let edge = "edge.enabled", edgeDelay = "edge.delay"
        static let placement = "panel.placement", width = "panel.width", height = "panel.heightFraction"
        static let freeFrame = "panel.freeFrame", onTop = "panel.alwaysOnTop", hideInactive = "panel.hideWhenInactive"
        static let escape = "panel.escapeHides", animations = "panel.animations", section = "panel.lastSection"
        static let menuIcon = "panel.menuBarIcon"
        static let engine = "browser.engine", home = "browser.home", zoom = "browser.zoom"
        static let fontSize = "terminal.fontSize", meta = "terminal.optionAsMeta", scrollback = "terminal.scrollback"
        static let shell = "terminal.shell", termEscape = "terminal.escapeHides", blink = "terminal.cursorBlink"
    }

    private init() {
        d.register(defaults: [
            K.edge: false, K.edgeDelay: 0.25,
            K.placement: PanelPlacement.right.rawValue, K.width: 560.0, K.height: 0.88,
            K.onTop: true, K.hideInactive: true, K.escape: true, K.animations: true,
            K.section: PanelSection.browser.rawValue, K.menuIcon: true,
            K.engine: SearchEngine.duckDuckGo.rawValue, K.home: "", K.zoom: 1.0,
            K.fontSize: 12.5, K.meta: false, K.scrollback: 10_000, K.shell: "",
            K.termEscape: true, K.blink: true,
        ])
        if d.object(forKey: K.hotKeyCode) != nil {
            hotKey = HotKey(keyCode: UInt32(d.integer(forKey: K.hotKeyCode)),
                            carbonModifiers: UInt32(d.integer(forKey: K.hotKeyMods)))
        } else {
            hotKey = .defaultToggle
        }
        edgeActivation = d.bool(forKey: K.edge)
        edgeDelay = d.double(forKey: K.edgeDelay)
        placement = PanelPlacement(rawValue: d.string(forKey: K.placement) ?? "") ?? .right
        panelWidth = d.double(forKey: K.width)
        panelHeightFraction = d.double(forKey: K.height)
        freeFrame = d.string(forKey: K.freeFrame).map { NSRectFromString($0) }
        alwaysOnTop = d.bool(forKey: K.onTop)
        hideWhenInactive = d.bool(forKey: K.hideInactive)
        escapeHides = d.bool(forKey: K.escape)
        animations = d.bool(forKey: K.animations)
        lastSection = PanelSection(rawValue: d.string(forKey: K.section) ?? "") ?? .browser
        showMenuBarIcon = d.bool(forKey: K.menuIcon)
        searchEngine = SearchEngine(rawValue: d.string(forKey: K.engine) ?? "") ?? .duckDuckGo
        homePage = d.string(forKey: K.home) ?? ""
        browserZoom = d.double(forKey: K.zoom)
        terminalFontSize = d.double(forKey: K.fontSize)
        optionAsMeta = d.bool(forKey: K.meta)
        scrollbackLines = d.integer(forKey: K.scrollback)
        shellPath = d.string(forKey: K.shell) ?? ""
        terminalEscapeHides = d.bool(forKey: K.termEscape)
        cursorBlink = d.bool(forKey: K.blink)
    }

    private func saveHotKey() {
        d.set(Int(hotKey.keyCode), forKey: K.hotKeyCode)
        d.set(Int(hotKey.carbonModifiers), forKey: K.hotKeyMods)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("SidePanel: launch-at-login change failed: \(error.localizedDescription)")
            }
        }
    }

    /// Whether the panel should honour reduced motion.
    var effectiveAnimations: Bool {
        animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func resetPanelGeometry() {
        placement = .right
        panelWidth = 560
        panelHeightFraction = 0.88
        freeFrame = nil
    }
}
