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

    // Idle: red cursorarrow. Click commit: blue cursorarrow.rays for ~150ms.
    private let idleSymbolName  = "cursorarrow"
    private let clickSymbolName = "cursorarrow.rays"
    private let idleTint: NSColor  = .systemRed
    private let clickTint: NSColor = .systemBlue

    private let idleImage:  NSImage?
    private let clickImage: NSImage?

    /// Monotonically incremented per flash so a delayed restore from an OLD
    /// flash doesn't clobber a NEW one that started in the meantime.
    private var flashGeneration: UInt64 = 0

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

        // Pre-render symbols (avoids per-flash NSImage construction).
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 26, weight: .bold)
            self.idleImage  = NSImage(systemSymbolName: idleSymbolName,  accessibilityDescription: "mMouse aim")?
                .withSymbolConfiguration(cfg)
            self.clickImage = NSImage(systemSymbolName: clickSymbolName, accessibilityDescription: "mMouse click")?
                .withSymbolConfiguration(cfg)
        } else {
            // Fallback for pre-Big Sur — same image both states, color flash only.
            let fb = CursorOverlay.fallbackImage(size: size, tint: idleTint)
            self.idleImage = fb
            self.clickImage = fb
        }

        imageView.image = self.idleImage
        imageView.contentTintColor = idleTint

        container.addSubview(imageView)
        panel.contentView = container

        self.panel = panel
        self.imageView = imageView
    }

    /// Shows the overlay at the given screen position (CG coordinates, top-left origin).
    func show(at point: CGPoint) {
        // Restore idle state on every show — covers the case where the user
        // deactivated mid-flash and re-activated before restore fired.
        flashGeneration &+= 1
        imageView.image = idleImage
        imageView.contentTintColor = idleTint
        move(to: point)
        panel.orderFrontRegardless()
    }

    func hide() {
        // Invalidate any pending flash restore — overlay is gone.
        flashGeneration &+= 1
        panel.orderOut(nil)
    }

    /// Updates overlay position to follow the aim. `point` is in CG coordinates
    /// (top-left origin, Y increases downward) — same coord system used by
    /// CGEvent and our MouseController.
    func move(to point: CGPoint) {
        let nsPoint = Self.cgToScreen(point, panelSize: size)
        panel.setFrameOrigin(nsPoint)
    }

    /// On click commit: swap to `cursorarrow.rays` (blue) for ~150ms then
    /// revert to idle `cursorarrow` (red). Visual confirmation that the click
    /// landed where the overlay was pointing.
    func flashClick() {
        flashGeneration &+= 1
        let gen = flashGeneration
        imageView.image = clickImage
        imageView.contentTintColor = clickTint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.flashGeneration == gen else { return }
            self.imageView.image = self.idleImage
            self.imageView.contentTintColor = self.idleTint
        }
    }

    /// Convert CG point (top-left origin) → NSWindow origin (bottom-left).
    /// Centers the panel on the target point.
    ///
    /// The global coordinate Y-flip uses the PRIMARY display's height — i.e.
    /// the display containing CG origin (0,0). `CGDisplayBounds(CGMainDisplayID())`
    /// is authoritative for this; `NSScreen.main` returns the screen with the
    /// key window (wrong on multi-monitor when the key window isn't on the
    /// primary), and `NSScreen.screens.first` is order-dependent.
    private static func cgToScreen(_ cg: CGPoint, panelSize: CGFloat) -> NSPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
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
