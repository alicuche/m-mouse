import AppKit
import CoreGraphics
import Foundation

/// Floating visual overlay shown at the "aim" position while mMouse is active.
/// The real mouse cursor doesn't move during aiming — this overlay does.
/// On click, EventTapManager warps the real cursor to the overlay's position
/// and posts the click event there.
@MainActor
final class CursorOverlay {

    private let panel: NSPanel
    private let imageView: NSImageView
    private let size: CGFloat = 36

    init() {
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let container = NSView(frame: frame)
        container.wantsLayer = true

        let imageView = NSImageView(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .systemBlue
        if #available(macOS 11.0, *) {
            let symbol = NSImage(systemSymbolName: "scope", accessibilityDescription: "mMouse cursor")
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
            imageView.image = symbol?.withSymbolConfiguration(cfg)
        } else {
            // Fallback: draw a simple ring + dot
            imageView.image = CursorOverlay.fallbackImage(size: size, tint: .systemBlue)
        }

        container.addSubview(imageView)
        panel.contentView = container

        self.panel = panel
        self.imageView = imageView
    }

    /// Shows the overlay at the given screen position (CG coordinates, top-left origin).
    func show(at point: CGPoint) {
        move(to: point)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Updates overlay position to follow the aim. `point` is in CG coordinates
    /// (top-left origin, Y increases downward) — same coord system used by
    /// CGEvent and our MouseController.
    func move(to point: CGPoint) {
        let nsPoint = Self.cgToScreen(point, panelSize: size)
        panel.setFrameOrigin(nsPoint)
    }

    /// Convert CG point (top-left origin) → NSWindow origin (bottom-left).
    /// Centers the panel on the target point.
    private static func cgToScreen(_ cg: CGPoint, panelSize: CGFloat) -> NSPoint {
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
                             ?? NSScreen.main
                             ?? NSScreen.screens.first)?.frame.height ?? 0
        return NSPoint(
            x: cg.x - panelSize / 2,
            y: primaryHeight - cg.y - panelSize / 2
        )
    }

    private static func fallbackImage(size: CGFloat, tint: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            ring.lineWidth = 2
            tint.setStroke()
            ring.stroke()
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: size/2 - 2, dy: size/2 - 2))
            tint.setFill()
            dot.fill()
            return true
        }
        return img
    }
}
