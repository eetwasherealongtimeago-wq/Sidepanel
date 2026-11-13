import AppKit
import SwiftUI

/// Transparent strip that lets the user drag the borderless panel around.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // Double-click snaps the panel back to its edge.
                AppSettings.shared.placement = AppSettings.shared.placement == .free ? .right : AppSettings.shared.placement
                return
            }
            window?.performDrag(with: event)
        }
    }
}

/// Invisible edge that resizes the panel. Width changes keep the docked edge fixed.
struct ResizeEdge: NSViewRepresentable {
    enum Edge { case left, right, top, bottom }
    let edge: Edge

    func makeNSView(context: Context) -> NSView { ResizeView(edge: edge) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ResizeView)?.edge = edge }

    final class ResizeView: NSView {
        var edge: Edge
        private var startFrame = NSRect.zero
        private var startMouse = NSPoint.zero

        init(edge: Edge) {
            self.edge = edge
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            let cursor: NSCursor = (edge == .left || edge == .right) ? .resizeLeftRight : .resizeUpDown
            addCursorRect(bounds, cursor: cursor)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startFrame = window.frame
            startMouse = NSEvent.mouseLocation
            controller?.isUserResizing = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            var f = startFrame
            let minW = window.minSize.width, minH = window.minSize.height
            switch edge {
            case .left:
                let w = max(minW, startFrame.width - dx)
                f.origin.x = startFrame.maxX - w
                f.size.width = w
            case .right:
                f.size.width = max(minW, startFrame.width + dx)
            case .bottom:
                let h = max(minH, startFrame.height - dy)
                f.origin.y = startFrame.maxY - h
                f.size.height = h
            case .top:
                f.size.height = max(minH, startFrame.height + dy)
            }
            if let screen = window.screen {
                f = f.intersection(screen.visibleFrame)
            }
            window.setFrame(f, display: true)
        }

        override func mouseUp(with event: NSEvent) {
            controller?.isUserResizing = false
        }

        private var controller: PanelController? {
            window?.delegate as? PanelController
        }
    }
}

/// Hosts an existing NSView (a WKWebView or TerminalView) inside SwiftUI without
/// SwiftUI ever recreating it. Swapping `view` swaps the hosted subview.
struct HostedView: NSViewRepresentable {
    let view: NSView
    var isActive: Bool = true

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== view {
            container.subviews.forEach { $0.removeFromSuperview() }
            view.removeFromSuperview()
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        if container.isHidden == isActive {
            container.isHidden = !isActive
            if isActive {
                container.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    container.animator().alphaValue = 1
                }
            }
        }
    }
}
