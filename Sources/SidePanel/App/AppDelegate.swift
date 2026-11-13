import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private var state: AppState!
    private var controller: PanelController!
    private var edgeActivator: EdgeActivator?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        state = AppState(settings: settings)
        controller = PanelController(state: state, settings: settings)
        edgeActivator = EdgeActivator(settings: settings, controller: controller)
        NSApp.mainMenu = MainMenu.build()

        HotKeyCenter.shared.onPress = { [weak self] in self?.controller.toggle() }
        registerHotKey()
        settings.$hotKey.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerHotKey() }
        }.store(in: &cancellables)

        updateStatusItem()
        settings.$showMenuBarIcon.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &cancellables)

        if let demo = ProcessInfo.processInfo.environment["SIDEPANEL_DEMO"] {
            runDemo(demo)
            return
        }

        // First launch: show the panel once so people know it exists.
        if !UserDefaults.standard.bool(forKey: "app.hasLaunched") {
            UserDefaults.standard.set(true, forKey: "app.hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.controller.show()
            }
        }
    }

    /// Used by CI to put the real app into a known state for screenshots:
    /// SIDEPANEL_DEMO=browser|terminal|settings
    private func runDemo(_ mode: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.controller.show()
            switch mode {
            case "terminal":
                self.state.section = .terminal
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    let script = "clear; echo; printf '\\033[1;32m  SidePanel terminal\\033[0m  —  '; uname -sm; "
                        + "for i in 1 2 3 4 5 6; do printf \"\\033[3${i}m██\\033[0m \"; done; echo; "
                        + "printf '\\033[38;2;110;242;194mtrue colour\\033[0m  \\033[1mbold\\033[0m  \\033[4munderline\\033[0m  漢字 ✓\\n'; "
                        + "ls -la /Applications | head -8; echo $TERM $COLORTERM\n"
                    self?.state.terminals.selected?.view.send?(Array(script.utf8))
                }
            case "settings":
                self.state.showSettings = true
            default:
                self.state.section = .browser
                if let url = URL(string: ProcessInfo.processInfo.environment["SIDEPANEL_DEMO_URL"] ?? "https://example.com") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.state.browser.open(url)
                    }
                }
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open -a`) toggles the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerHotKey() {
        state.hotKeyConflict = !HotKeyCenter.shared.register(settings.hotKey)
    }

    // MARK: Menu bar item

    private func updateStatusItem() {
        if settings.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = StatusGlyph.image()
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if !isRightClick {
            controller.toggle()
            return
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: controller.isShown ? "Hide SidePanel" : "Show SidePanel",
                                action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SidePanel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func togglePanel() { controller.toggle() }

    @objc private func openSettings() {
        controller.show()
        state.showSettings = true
    }
}

/// The menu-bar glyph: a screen outline with a lit panel on its edge. Drawn in
/// code as a template image so it adapts to light and dark menu bars.
enum StatusGlyph {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let outer = NSBezierPath(roundedRect: NSRect(x: 2, y: 3.5, width: 14, height: 11), xRadius: 3, yRadius: 3)
            outer.lineWidth = 1.4
            outer.stroke()
            let panel = NSBezierPath(roundedRect: NSRect(x: 10.2, y: 5.4, width: 3.9, height: 7.2), xRadius: 1.3, yRadius: 1.3)
            panel.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
