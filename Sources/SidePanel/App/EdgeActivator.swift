import AppKit

/// Reveals the panel when the pointer rests against the screen edge the panel
/// is docked to. Polls the pointer position, which needs no special permissions.
@MainActor
final class EdgeActivator: NSObject {
    private let settings: AppSettings
    private weak var controller: PanelController?
    private var timer: Timer?
    private var dwellStart: Date?
    private var armed = true

    init(settings: AppSettings, controller: PanelController) {
        self.settings = settings
        self.controller = controller
        super.init()
        let t = Timer(timeInterval: 0.06, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        guard settings.edgeActivation, let controller else {
            dwellStart = nil
            return
        }
        if controller.isShown {
            dwellStart = nil
            armed = false
            return
        }
        let atEdge = pointerIsAtActivationEdge()
        if !atEdge {
            dwellStart = nil
            armed = true
            return
        }
        guard armed, NSEvent.pressedMouseButtons == 0 else { return }
        if let start = dwellStart {
            if Date().timeIntervalSince(start) >= settings.edgeDelay {
                dwellStart = nil
                armed = false
                controller.show()
            }
        } else {
            dwellStart = Date()
        }
    }

    private func pointerIsAtActivationEdge() -> Bool {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        let f = screen.frame
        let tolerance: CGFloat = 1.5
        // Stay away from the corners so hot corners and the Dock keep working.
        let verticalBand = (f.minY + f.height * 0.15)...(f.maxY - f.height * 0.15)
        let horizontalBand = (f.minX + f.width * 0.3)...(f.maxX - f.width * 0.3)
        switch settings.placement {
        case .right:
            return p.x >= f.maxX - tolerance && verticalBand.contains(p.y) && !hasNeighbour(screen, toTheRight: true)
        case .left:
            return p.x <= f.minX + tolerance && verticalBand.contains(p.y) && !hasNeighbour(screen, toTheRight: false)
        case .center, .free:
            return p.y >= f.maxY - tolerance && horizontalBand.contains(p.x)
        }
    }

    /// On multi-display setups the shared edge between two screens isn't a real edge.
    private func hasNeighbour(_ screen: NSScreen, toTheRight: Bool) -> Bool {
        let f = screen.frame
        return NSScreen.screens.contains { other in
            guard other != screen else { return false }
            let o = other.frame
            let overlapsVertically = o.maxY > f.minY && o.minY < f.maxY
            return overlapsVertically && (toTheRight ? abs(o.minX - f.maxX) < 1 : abs(o.maxX - f.minX) < 1)
        }
    }
}
