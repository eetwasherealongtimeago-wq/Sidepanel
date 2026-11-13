import AppKit

@main
struct SidePanelMain {
    /// SidePanel runs as a background accessory: no Dock icon, no menu bar of its own.
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
