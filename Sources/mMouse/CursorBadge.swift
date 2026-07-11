import AppKit
import CoreGraphics
import Foundation

/// Small floating dot anchored to the bottom-right of the system cursor.
/// Acts as a passive status indicator while mMouse is active:
/// - Red when idle (you are in active mode)
/// - Brief green flash when a click / right-click / drag start / drag end fires
///
/// The badge does NOT control the cursor — it only follows it. Cursor movement
/// is driven by MouseController (which warps the real system cursor directly).
/// A 60Hz polling timer in EventTapManager reads the cursor position and calls
/// `move(to:)` here.
@MainActor
final class CursorBadge {

    private let panel: NSPanel
    private let imageView: NSImageView

    /// Diameter of the visible dot. Kept small so it never interferes with
    /// what's under the cursor.
    private let size: CGFloat = 10

    /// Pixel offset from the cursor hotspot to the badge's panel-origin (top-
    /// left of the badge in CG coords). Tuned to sit snugly next to the
    /// cursor's tip — slightly right of and slightly below the hotspot, but
    /// close enough that the eye reads "cursor + badge" as one unit.
    private let offsetX: CGFloat = 6
    private let offsetY: CGFloat = 4

    private let idleTint:   NSColor = .systemRed
    private let actionTint: NSColor = .systemGreen
    /// Shown while saved-spot recording is armed — a distinct amber so the user
    /// can SEE the recorder is waiting for a slot key.
    private let recordTint: NSColor = .systemOrange

    /// True while saved-spot recording is armed. Makes the idle tint amber so a
    /// restored colour (after a flash) keeps showing the armed state.
    private var isRecording: Bool = false

    /// Bumps on every show/hide/flash so a stale restore from an OLD flash
    /// can't clobber a NEW state (rapid-fire clicks, deactivate mid-flash).
    private var flashGen: UInt64 = 0

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
        // Stay above popup menus so the badge remains visible while a
        // right-click menu is open — same rationale as the old aim overlay.
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        panel.level = NSWindow.Level(rawValue: popUpLevel + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let container = NSView(frame: frame)
        container.wantsLayer = true

        let imageView = NSImageView(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = CursorBadge.dotImage(diameter: size, fill: idleTint)
        container.addSubview(imageView)
        panel.contentView = container

        self.panel = panel
        self.imageView = imageView
    }

    /// Show the badge anchored to the given cursor position (CG coords).
    func show(at cursor: CGPoint) {
        flashGen &+= 1
        setIdleColor()
        move(to: cursor)
        panel.orderFrontRegardless()
    }

    func hide() {
        flashGen &+= 1
        panel.orderOut(nil)
    }

    /// Update badge position to follow the cursor. `cursor` is in CG coords
    /// (top-left origin, Y down) — same coord space MouseController uses.
    func move(to cursor: CGPoint) {
        let nsOrigin = Self.panelOriginForCursor(
            cursor,
            panelSize: size,
            offsetX: offsetX,
            offsetY: offsetY
        )
        panel.setFrameOrigin(nsOrigin)
    }

    /// Brief green flash to confirm a click / drag-start / drag-end / etc.
    func flashAction() {
        flashGen &+= 1
        let gen = flashGen
        imageView.image = CursorBadge.dotImage(diameter: size, fill: actionTint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.flashGen == gen else { return }
            self.setIdleColor()
        }
    }

    /// Toggle the armed-recording visual (amber dot). Persists across click
    /// flashes until turned off.
    func setRecording(_ on: Bool) {
        isRecording = on
        flashGen &+= 1
        setIdleColor()
    }

    private func setIdleColor() {
        let tint = isRecording ? recordTint : idleTint
        imageView.image = CursorBadge.dotImage(diameter: size, fill: tint)
    }

    /// Pre-rendered solid dot. Cheap enough to redraw on tint change since
    /// the image is tiny (10×10).
    private static func dotImage(diameter: CGFloat, fill: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            // 1px white stroke for visibility on any background.
            let inset = rect.insetBy(dx: 1, dy: 1)
            let circle = NSBezierPath(ovalIn: inset)
            fill.setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            circle.lineWidth = 0.8
            circle.stroke()
            return true
        }
        return img
    }

    /// Convert CG cursor point (top-left origin) → NSPanel origin
    /// (NS bottom-left of the panel's frame). The badge is anchored to the
    /// cursor's bottom-right, so the panel sits at:
    ///   x = cursor.x + offsetX  (panel left edge, slightly right of cursor)
    ///   y_cg_top = cursor.y + offsetY  (panel top edge, slightly below cursor)
    /// then flip Y to NS using the primary display's height (CG and NS share
    /// global coordinates; only the origin differs).
    private static func panelOriginForCursor(
        _ cursor: CGPoint,
        panelSize: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) -> NSPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cgTopLeftX = cursor.x + offsetX
        let cgTopLeftY = cursor.y + offsetY
        return NSPoint(
            x: cgTopLeftX,
            y: primaryHeight - cgTopLeftY - panelSize
        )
    }
}
