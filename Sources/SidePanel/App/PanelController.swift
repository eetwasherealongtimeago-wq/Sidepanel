import AppKit
import Combine
import SwiftUI

/// Owns the panel window: showing, hiding, animating, positioning, and the
/// keyboard behaviour that belongs to the panel as a whole.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: FloatingPanel
    let state: AppState
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private(set) var isShown = false
    private var isAnimating = false
    private var programmaticFrameChange = false
    /// Set by the in-panel resize handles (and live resize) so edge-resizing doesn't count as a move.
    var isUserResizing = false
    private var escapeMonitor: Any?

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
        self.panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: settings.panelWidth, height: 700))
        super.init()

        let root = RootView()
            .environmentObject(state)
            .environmentObject(settings)
            .environmentObject(state.browser)
            .environmentObject(state.terminals)
        let hosting = NSHostingView(rootView: root)
        panel.contentView = PanelContentView(content: hosting)
        panel.delegate = self
        state.panel = self

        applyLevel()
        settings.$alwaysOnTop.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLevel() }
        }.store(in: &cancellables)
        settings.$placement.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reposition(animated: true) }
        }.store(in: &cancellables)

        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        installEscapeMonitor()
    }

    // MARK: Show / hide

    func toggle() {
        if isShown && panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        let screen = screenForPresentation()
        let target = targetFrame(on: screen)
        let wasShown = isShown
        isShown = true

        NSApp.activate(ignoringOtherApps: true)
        if wasShown && panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            state.focusActiveSection()
            return
        }

        let animate = settings.effectiveAnimations
        programmaticFrameChange = true
        if animate {
            panel.setFrame(offsetFrame(target, on: screen), display: false)
            panel.alphaValue = 0
        } else {
            panel.setFrame(target, display: false)
            panel.alphaValue = 1
        }
        panel.makeKeyAndOrderFront(nil)
        state.focusActiveSection()

        guard animate else {
            programmaticFrameChange = false
            return
        }
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isAnimating = false
                self?.programmaticFrameChange = false
            }
        })
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        state.prepareForHide()
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.isAnimating = false
            self.programmaticFrameChange = false
            // Hand focus back to whatever the user was doing before.
            if NSApp.isActive && !NSApp.windows.contains(where: { $0.isVisible && $0 !== self.panel && $0.level == .normal && $0.canBecomeKey }) {
                NSApp.hide(nil)
            }
        }
        guard settings.effectiveAnimations, let screen = panel.screen ?? NSScreen.main else {
            finish()
            return
        }
        isAnimating = true
        programmaticFrameChange = true
        let end = offsetFrame(panel.frame, on: screen)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in finish() }
        })
    }

    private func applyLevel() {
        panel.level = settings.alwaysOnTop ? .floating : .normal
        state.objectWillChange.send()
    }

    // MARK: Geometry

    private func screenForPresentation() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if settings.placement == .free, let saved = settings.freeFrame,
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) }) {
            return screen
        }
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func targetFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let margin: CGFloat = 10
        let width = min(max(settings.panelWidth, panel.minSize.width), vf.width - margin * 2)
        let height = min(max(vf.height * settings.panelHeightFraction, panel.minSize.height), vf.height - margin * 2)

        switch settings.placement {
        case .right:
            return NSRect(x: vf.maxX - width - margin, y: vf.midY - height / 2, width: width, height: height).integral
        case .left:
            return NSRect(x: vf.minX + margin, y: vf.midY - height / 2, width: width, height: height).integral
        case .center:
            return NSRect(x: vf.midX - width / 2, y: vf.maxY - height - margin, width: width, height: height).integral
        case .free:
            if var f = settings.freeFrame {
                f.size.width = min(max(f.width, panel.minSize.width), vf.width)
                f.size.height = min(max(f.height, panel.minSize.height), vf.height)
                f.origin.x = min(max(f.minX, vf.minX), vf.maxX - f.width)
                f.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
                return f.integral
            }
            return NSRect(x: vf.maxX - width - margin, y: vf.midY - height / 2, width: width, height: height).integral
        }
    }

    /// Where the panel slides in from: just beyond its docked edge.
    private func offsetFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        var f = frame
        switch settings.placement {
        case .right: f.origin.x += 28
        case .left: f.origin.x -= 28
        case .center, .free: f.origin.y += 18
        }
        return f
    }

    func reposition(animated: Bool) {
        guard isShown, let screen = panel.screen ?? NSScreen.main else { return }
        let target = targetFrame(on: screen)
        programmaticFrameChange = true
        if animated && settings.effectiveAnimations {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                Task { @MainActor in self?.programmaticFrameChange = false }
            })
        } else {
            panel.setFrame(target, display: true)
            programmaticFrameChange = false
        }
    }

    @objc private func screensChanged() {
        reposition(animated: false)
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard isShown, !programmaticFrameChange, !isAnimating, let screen = panel.screen else { return }
        let frame = panel.frame
        if settings.placement == .free {
            settings.freeFrame = frame
        } else {
            settings.panelWidth = Double(frame.width)
            settings.panelHeightFraction = Double(min(1, frame.height / screen.visibleFrame.height))
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) { isUserResizing = true }
    func windowDidEndLiveResize(_ notification: Notification) { isUserResizing = false }

    func windowDidMove(_ notification: Notification) {
        guard isShown, !programmaticFrameChange, !isAnimating, !isUserResizing else { return }
        // Dragging a docked panel un-docks it.
        if settings.placement != .free { settings.placement = .free }
        settings.freeFrame = panel.frame
    }

    @objc private func appDidResignActive() {
        guard isShown, settings.hideWhenInactive, !isAnimating else { return }
        // Don't vanish while a sheet (file chooser, JS alert) is up.
        if panel.attachedSheet != nil { return }
        hide()
    }

    // MARK: Escape

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.panel else { return event }
            return self.handleEscape(event) ? nil : event
        }
    }

    /// Returns true when Escape was consumed by the panel.
    private func handleEscape(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if panel.attachedSheet != nil { return false }
        if state.dismissTransientUI() { return true }
        // ⇧⎋ always hides, even from inside full-screen terminal programs.
        if flags.contains(.shift) { hide(); return true }
        guard settings.escapeHides, flags.isEmpty else { return false }
        if state.section == .terminal, state.terminals.wantsEscapeKey { return false }
        hide()
        return true
    }
}
