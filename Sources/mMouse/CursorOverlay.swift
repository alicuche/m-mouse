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
    // Panel size — kept slim so the overlay doesn't cover the text or UI
    // element the user is aiming at. Icon point sizes are even smaller (see
    // init) and centered inside this frame.
    private let size: CGFloat = 22

    // Idle: red cursorarrow. Click commit: blue cursorarrow.rays for ~150ms.
    // Drag mode (vim-style `v` toggle): green I-beam (slim text caret) so it
    // doesn't cover the characters being selected.
    private let idleSymbolName  = "cursorarrow"
    private let clickSymbolName = "cursorarrow.rays"
    private let dragSymbolName  = "character.cursor.ibeam"
    private let idleTint:  NSColor = .systemRed
    private let clickTint: NSColor = .systemBlue
    private let dragTint:  NSColor = .systemGreen

    private let idleImage:  NSImage?
    private let clickImage: NSImage?
    private let dragImage:  NSImage?
    private var inDragMode: Bool = false

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
        // Slim sizes so the overlay doesn't visually dominate. Drag is even
        // smaller + lighter weight so the I-beam doesn't cover letters during
        // text selection — precision matters here.
        if #available(macOS 11.0, *) {
            let pointerCfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let ibeamCfg   = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            self.idleImage  = NSImage(systemSymbolName: idleSymbolName,  accessibilityDescription: "mMouse aim")?
                .withSymbolConfiguration(pointerCfg)
            self.clickImage = NSImage(systemSymbolName: clickSymbolName, accessibilityDescription: "mMouse click")?
                .withSymbolConfiguration(pointerCfg)
            // `character.cursor.ibeam` exists from SF Symbols 4 / macOS 13.
            // Fall back to a hand-drawn vertical bar if missing on older OS.
            let ibeam = NSImage(systemSymbolName: dragSymbolName, accessibilityDescription: "mMouse drag")?
                .withSymbolConfiguration(ibeamCfg)
            self.dragImage = ibeam ?? CursorOverlay.iBeamFallback(size: size, tint: dragTint)
        } else {
            // Fallback for pre-Big Sur — same image all states, color tint only.
            let fb = CursorOverlay.fallbackImage(size: size, tint: idleTint)
            self.idleImage  = fb
            self.clickImage = fb
            self.dragImage  = CursorOverlay.iBeamFallback(size: size, tint: dragTint)
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
        inDragMode = false
        imageView.image = idleImage
        imageView.contentTintColor = idleTint
        move(to: point)
        panel.orderFrontRegardless()
    }

    func hide() {
        // Invalidate any pending flash restore — overlay is gone.
        flashGeneration &+= 1
        inDragMode = false
        panel.orderOut(nil)
    }

    /// Switch overlay to drag visual (orange lasso) or back to idle.
    /// Bumps generation so any in-flight flash restore won't clobber the new state.
    func setDragMode(_ active: Bool) {
        flashGeneration &+= 1
        inDragMode = active
        if active {
            imageView.image = dragImage
            imageView.contentTintColor = dragTint
        } else {
            imageView.image = idleImage
            imageView.contentTintColor = idleTint
        }
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
            // Restore to whichever resting state we were in (idle OR drag).
            if self.inDragMode {
                self.imageView.image = self.dragImage
                self.imageView.contentTintColor = self.dragTint
            } else {
                self.imageView.image = self.idleImage
                self.imageView.contentTintColor = self.idleTint
            }
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

    /// Slim vertical-bar I-beam used when `character.cursor.ibeam` symbol is
    /// unavailable. Hand-drawn so it always renders consistently.
    private static func iBeamFallback(size: CGFloat, tint: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            tint.setFill()
            // 2px-wide vertical bar centered, with 1px serifs top/bottom.
            let barWidth: CGFloat  = 2
            let barHeight: CGFloat = max(rect.height * 0.7, 10)
            let cx = rect.midX
            let cy = rect.midY
            let bar = NSRect(x: cx - barWidth/2, y: cy - barHeight/2, width: barWidth, height: barHeight)
            bar.fill()
            let serif = NSRect(x: cx - 4, y: bar.minY - 1, width: 8, height: 1)
            serif.fill()
            let serif2 = NSRect(x: cx - 4, y: bar.maxY, width: 8, height: 1)
            serif2.fill()
            return true
        }
        return img
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
