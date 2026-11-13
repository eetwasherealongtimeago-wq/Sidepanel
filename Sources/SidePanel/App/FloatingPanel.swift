import AppKit

/// The borderless, rounded window that hosts the whole interface.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 380, height: 420)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Borderless windows don't get ⌘-key handling for "Close"; route it to the tab instead.
    override func performClose(_ sender: Any?) {
        NSApp.sendAction(#selector(PanelCommands.closeTab(_:)), to: nil, from: sender)
    }
}

/// Selectors the hidden main menu sends down the responder chain.
@MainActor @objc protocol PanelCommands {
    func newTab(_ sender: Any?)
    func closeTab(_ sender: Any?)
    func nextTab(_ sender: Any?)
    func previousTab(_ sender: Any?)
    func showBrowser(_ sender: Any?)
    func showTerminal(_ sender: Any?)
    func focusAddressBar(_ sender: Any?)
    func reloadPage(_ sender: Any?)
    func goBack(_ sender: Any?)
    func goForward(_ sender: Any?)
    func toggleBookmark(_ sender: Any?)
    func showLibrary(_ sender: Any?)
    func showDownloads(_ sender: Any?)
    func showSettings(_ sender: Any?)
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
    func zoomReset(_ sender: Any?)
    func clearTerminal(_ sender: Any?)
    func hidePanel(_ sender: Any?)
    func togglePinned(_ sender: Any?)
    func selectTabByNumber(_ sender: Any?)
}

/// Container that gives the SwiftUI content its rounded, translucent body.
final class PanelContentView: NSView {
    let effectView = NSVisualEffectView()

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        addSubview(content)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
