import AppKit
import CoreGraphics
import Foundation

/// Large red arrow pointer (white outline) drawn exactly over the system
/// cursor while mMouse is active — the real cursor is hidden meanwhile, so this
/// IS the pointer you see. Its tip sits on the click hotspot.
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

    /// Arrow geometry: a classic pointer scaled by `arrowScale` (design units
    /// are 12×20 ≈ the system arrow), plus `pad` around it for the white
    /// stroke + shadow. The arrow tip is at (pad, pad) from the panel's top-left.
    private static let arrowScale: CGFloat = 1.3
    private static let pad: CGFloat = 4
    private static let panelW: CGFloat = 12 * arrowScale + pad * 2
    private static let panelH: CGFloat = 20 * arrowScale + pad * 2

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
        let frame = NSRect(x: 0, y: 0, width: Self.panelW, height: Self.panelH)
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
        imageView.image = CursorBadge.arrowImage(fill: idleTint)
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
        SystemCursor.hide()
    }

    func hide() {
        flashGen &+= 1
        panel.orderOut(nil)
        SystemCursor.show()
    }

    /// Update badge position to follow the cursor. `cursor` is in CG coords
    /// (top-left origin, Y down) — same coord space MouseController uses.
    func move(to cursor: CGPoint) {
        SystemCursor.reassert()
        // Tip of the arrow (at pad,pad inside the panel) lands on the hotspot.
        let nsOrigin = Self.panelOriginForCursor(
            cursor,
            panelHeight: Self.panelH,
            offsetX: -Self.pad,
            offsetY: -Self.pad
        )
        panel.setFrameOrigin(nsOrigin)
    }

    /// Brief green flash to confirm a click / drag-start / drag-end / etc.
    func flashAction() {
        flashGen &+= 1
        let gen = flashGen
        imageView.image = CursorBadge.arrowImage(fill: actionTint)
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
        imageView.image = CursorBadge.arrowImage(fill: tint)
    }

    /// Arrow images are cached per tint (only 3 colours) — flashes swap them.
    private static var arrowCache: [NSColor: NSImage] = [:]

    /// Classic pointer: coloured fill, thick white outline, soft shadow so it
    /// reads on both light and dark backgrounds.
    private static func arrowImage(fill: NSColor) -> NSImage {
        if let cached = arrowCache[fill] { return cached }
        let img = NSImage(size: NSSize(width: panelW, height: panelH), flipped: true) { _ in
            // Design-unit outline (top-left origin, Y down), tip at (0,0).
            let pts: [(CGFloat, CGFloat)] = [
                (0, 0), (0, 17), (4, 13.2), (6.8, 19.6), (9.6, 18.4),
                (6.9, 12.2), (12, 12.2),
            ]
            let path = NSBezierPath()
            for (i, p) in pts.enumerated() {
                let pt = NSPoint(x: pad + p.0 * arrowScale, y: pad + p.1 * arrowScale)
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 2.0

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 2.5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()

            fill.setFill()
            path.fill()
            return true
        }
        arrowCache[fill] = img
        return img
    }

    /// Convert CG cursor point (top-left origin) → NSPanel origin
    /// (NS bottom-left of the panel's frame). The panel's top-left sits at:
    ///   x = cursor.x + offsetX, y_cg_top = cursor.y + offsetY
    /// (the arrow passes -pad so its tip lands exactly on the hotspot),
    /// then flip Y to NS using the primary display's height (CG and NS share
    /// global coordinates; only the origin differs).
    private static func panelOriginForCursor(
        _ cursor: CGPoint,
        panelHeight: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) -> NSPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cgTopLeftX = cursor.x + offsetX
        let cgTopLeftY = cursor.y + offsetY
        return NSPoint(
            x: cgTopLeftX,
            y: primaryHeight - cgTopLeftY - panelHeight
        )
    }
}

/// Hides the real system cursor while mMouse is active (the red arrow replaces
/// it). A background app can't normally hide the cursor, so we set the
/// (private, long-stable) "SetsCursorInBackground" connection property first.
/// Hide/show calls are reference-counted by the window server, so we keep our
/// own flag to issue exactly one hide per show. If mMouse dies, the window
/// server restores the cursor automatically.
@MainActor
enum SystemCursor {
    private static var hidden = false
    private static var backgroundEnabled = false
    /// How many hide calls we've issued since the last show. Normally 1, but
    /// other apps (cursor-rect updates, app switches, Mission Control, Dock)
    /// can make the cursor visible again behind our back; `reassert()` then
    /// hides again and bumps this so `show()` can balance every call.
    private static var hideCount = 0

    static func hide() {
        guard !hidden else { return }
        if !backgroundEnabled {
            let cid = _CGSDefaultConnection()
            _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
            backgroundEnabled = true
        }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount = 1
        hidden = true
    }

    /// Called from the 60Hz badge-follow tick: if something re-showed the
    /// real cursor while we're active, hide it again.
    static func reassert() {
        guard hidden, _cursorIsVisible() != 0 else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    static func show() {
        guard hidden else { return }
        // Balance every hide we issued (extra shows at count 0 are no-ops),
        // then make sure it's really back.
        for _ in 0..<max(hideCount, 1) { CGDisplayShowCursor(CGMainDisplayID()) }
        var guardN = 0
        while _cursorIsVisible() == 0 && guardN < 16 {
            CGDisplayShowCursor(CGMainDisplayID()); guardN += 1
        }
        hideCount = 0
        hidden = false
    }
}

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ targetCID: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// `CGCursorIsVisible` is marked unavailable in Swift but still exported by
/// CoreGraphics; bind it directly.
@_silgen_name("CGCursorIsVisible")
private func _cursorIsVisible() -> Int32
