import AppKit

/// SidePanel is a background (LSUIElement) app, so this menu is never shown.
/// It exists so standard key equivalents — ⌘C, ⌘V, ⌘T, ⌘L, … — reach the
/// responder chain while the panel is key.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "SidePanel")
        appMenu.addItem(item("Settings…", #selector(PanelCommands.showSettings(_:)), ","))
        appMenu.addItem(item("Hide Panel", #selector(PanelCommands.hidePanel(_:)), "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit SidePanel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let panelItem = NSMenuItem()
        let panel = NSMenu(title: "Panel")
        panel.addItem(item("New Tab", #selector(PanelCommands.newTab(_:)), "t"))
        panel.addItem(item("Close Tab", #selector(PanelCommands.closeTab(_:)), "w"))
        panel.addItem(item("Next Tab", #selector(PanelCommands.nextTab(_:)), "\t", [.control]))
        panel.addItem(item("Previous Tab", #selector(PanelCommands.previousTab(_:)), "\t", [.control, .shift]))
        panel.addItem(item("Next Tab", #selector(PanelCommands.nextTab(_:)), "]", [.command, .shift]))
        panel.addItem(item("Previous Tab", #selector(PanelCommands.previousTab(_:)), "[", [.command, .shift]))
        for n in 1...9 {
            let i = item("Tab \(n)", #selector(PanelCommands.selectTabByNumber(_:)), "\(n)", [.command, .option])
            i.tag = n
            panel.addItem(i)
        }
        panel.addItem(.separator())
        panel.addItem(item("Browser", #selector(PanelCommands.showBrowser(_:)), "1"))
        panel.addItem(item("Terminal", #selector(PanelCommands.showTerminal(_:)), "2"))
        panel.addItem(item("Pin on Top", #selector(PanelCommands.togglePinned(_:)), "p", [.command, .shift]))
        panel.addItem(.separator())
        panel.addItem(item("Zoom In", #selector(PanelCommands.zoomIn(_:)), "="))
        panel.addItem(item("Zoom In", #selector(PanelCommands.zoomIn(_:)), "+"))
        panel.addItem(item("Zoom Out", #selector(PanelCommands.zoomOut(_:)), "-"))
        panel.addItem(item("Actual Size", #selector(PanelCommands.zoomReset(_:)), "0"))
        panelItem.submenu = panel
        main.addItem(panelItem)

        let browserItem = NSMenuItem()
        let browser = NSMenu(title: "Browser")
        browser.addItem(item("Open Location", #selector(PanelCommands.focusAddressBar(_:)), "l"))
        browser.addItem(item("Reload", #selector(PanelCommands.reloadPage(_:)), "r"))
        browser.addItem(item("Back", #selector(PanelCommands.goBack(_:)), "["))
        browser.addItem(item("Forward", #selector(PanelCommands.goForward(_:)), "]"))
        browser.addItem(item("Bookmark Page", #selector(PanelCommands.toggleBookmark(_:)), "d"))
        browser.addItem(item("Library", #selector(PanelCommands.showLibrary(_:)), "y"))
        browser.addItem(item("Downloads", #selector(PanelCommands.showDownloads(_:)), "l", [.command, .option]))
        browserItem.submenu = browser
        main.addItem(browserItem)

        let termItem = NSMenuItem()
        let term = NSMenu(title: "Terminal")
        term.addItem(item("Clear", #selector(PanelCommands.clearTerminal(_:)), "k"))
        termItem.submenu = term
        main.addItem(termItem)

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }
}
