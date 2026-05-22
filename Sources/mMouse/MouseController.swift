import AppKit
import CoreGraphics
import Foundation

/// Direct real-cursor control. Movement keys warp the system cursor; click /
/// scroll / drag are dispatched at the cursor's current position. No floating
/// aim overlay — what you see is the system cursor, and it really moves.
final class MouseController: @unchecked Sendable {
    private var moveTimer: DispatchSourceTimer?
    private var activeDirections: Set<Direction> = []
    private var tickAccumX: Double = 0
    private var tickAccumY: Double = 0

    /// Timestamp of current movement burst — used for acceleration.
    /// Short taps stay slow (precision); held keys ramp up to full speed.
    private var movementStartedAt: TimeInterval?

    /// Cached display bounds invalidated by screen-change notifications.
    private var cachedDisplayBounds: [CGRect] = []
    private var screenObserver: NSObjectProtocol?

    /// Fixed 60Hz movement loop — smoothness, not speed.
    private let tickRate: Double = 60

    enum Direction: Hashable {
        case up, down, left, right
    }

    /// Speed level 1..10 (clamped). 1 = slowest, 10 = fastest.
    var speedLevel: Int = 5

    /// Active multiplier from external boost modifier (default 1× = off).
    /// Applied on top of `pixelsPerTickBase` and `accelMultiplier()`.
    private var boostMultiplier: Double = 1.0

    func setBoost(_ multiplier: Double) {
        boostMultiplier = max(0.1, multiplier)
    }

    /// Base pixels per tick (before acceleration). Quadratic so:
    /// - speed 1 → ~0.5 px/tick (60 px/s base) — precision
    /// - speed 3 → ~4.5 px/tick (270 px/s base) — text-cursor-ish default
    /// - speed 5 → ~12.5 px/tick (750 px/s base)
    /// - speed 10 → 50 px/tick (3000 px/s base) — fast crossing
    private var pixelsPerTickBase: Double {
        let clamped = max(1, min(10, speedLevel))
        return max(1.0, Double(clamped * clamped) * 0.5)
    }

    /// Acceleration curve: short tap stays slow (precision), held key ramps up.
    /// - 0–100ms: 0.3× (precise tap)
    /// - 100–400ms: linear ramp 0.3× → 2.5×
    /// - 400ms+: 2.5× (fast crossing)
    private func accelMultiplier() -> Double {
        guard let start = movementStartedAt else { return 1.0 }
        let elapsed = CACurrentMediaTime() - start
        if elapsed < 0.1 { return 0.3 }
        if elapsed < 0.4 {
            let t = (elapsed - 0.1) / 0.3
            return 0.3 + (2.5 - 0.3) * t
        }
        return 2.5
    }

    init() {
        refreshDisplayCache()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDisplayCache()
        }
    }

    deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        moveTimer?.cancel()
        scrollTimer?.cancel()
    }

    // MARK: - Direction press/release

    func press(_ direction: Direction) {
        if activeDirections.isEmpty {
            movementStartedAt = CACurrentMediaTime()
        }
        activeDirections.insert(direction)
        startTimerIfNeeded()
    }

    func release(_ direction: Direction) {
        activeDirections.remove(direction)
        if activeDirections.isEmpty {
            stopTimer()
        }
    }

    func releaseAll() {
        activeDirections.removeAll()
        stopTimer()
    }

    // MARK: - Click actions

    /// Post a left click at the current cursor position.
    /// `count=1` → single click. `count=2` after a count=1 registers as double-click.
    func click(count: Int = 1) {
        let pos = realCursorPosition()
        let clamped = max(1, min(3, count))
        postMouseEvent(.leftMouseDown, at: pos, button: .left, clickCount: Int64(clamped))
        postMouseEvent(.leftMouseUp,   at: pos, button: .left, clickCount: Int64(clamped))
    }

    func rightClick() {
        let pos = realCursorPosition()
        postMouseEvent(.rightMouseDown, at: pos, button: .right, clickCount: 1)
        postMouseEvent(.rightMouseUp,   at: pos, button: .right, clickCount: 1)
    }

    // MARK: - Drag (vim-style visual mode)

    /// True from `startDrag()` until `endDrag()`. While true, `tick()` posts
    /// `leftMouseDragged` events after each warp so apps render the selection
    /// rectangle / drag operation.
    private(set) var isDragging: Bool = false

    /// Begin a drag at the current cursor position. Posts `leftMouseDown` then
    /// leaves the button held until `endDrag()`. Idempotent — guarded by the
    /// `isDragging` flag.
    func startDrag() {
        guard !isDragging else { return }
        let pos = realCursorPosition()
        postMouseEvent(.leftMouseDown, at: pos, button: .left, clickCount: 1)
        isDragging = true
        print("[mMouse] drag start at (\(Int(pos.x)),\(Int(pos.y)))")
    }

    /// End a drag — posts `leftMouseUp` at current cursor position. Safe to
    /// call when not dragging (no-op).
    func endDrag() {
        guard isDragging else { return }
        let pos = realCursorPosition()
        postMouseEvent(.leftMouseUp, at: pos, button: .left, clickCount: 1)
        isDragging = false
        print("[mMouse] drag end at (\(Int(pos.x)),\(Int(pos.y)))")
    }

    // MARK: - Scroll

    private var scrollTimer: DispatchSourceTimer?
    private var activeScrollDirections: Set<Direction> = []
    private var scrollStartedAt: TimeInterval?

    /// Pixels per scroll tick. We use pixel units (not line units) because
    /// many modern apps — especially Electron/Chromium based ones — ignore or
    /// poorly handle .line units. 8 px/tick × 60 ticks/sec = 480 px/s baseline.
    private let scrollTickRate: Double = 60 // 60 ticks/sec, matches movement
    private let scrollPixelsPerTick: Int32 = 8

    func pressScroll(_ direction: Direction) {
        if activeScrollDirections.isEmpty {
            scrollStartedAt = CACurrentMediaTime()
            print("[mMouse] scroll start dir=\(direction)")
        }
        activeScrollDirections.insert(direction)
        startScrollTimerIfNeeded()
    }

    func releaseScroll(_ direction: Direction) {
        activeScrollDirections.remove(direction)
        if activeScrollDirections.isEmpty {
            stopScroll()
        }
    }

    func stopScroll() {
        scrollTimer?.cancel()
        scrollTimer = nil
        activeScrollDirections.removeAll()
        scrollStartedAt = nil
    }

    private func startScrollTimerIfNeeded() {
        guard scrollTimer == nil else { return }
        let interval = 1.0 / scrollTickRate
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.scrollTick() }
        timer.resume()
        scrollTimer = timer
    }

    private func scrollTick() {
        guard !activeScrollDirections.isEmpty else { stopScroll(); return }

        // Acceleration: tap stays gentle, hold ramps up to 3× after ~500ms.
        let elapsed = scrollStartedAt.map { CACurrentMediaTime() - $0 } ?? 0
        let mult: Int32
        if elapsed < 0.1       { mult = 1 }
        else if elapsed < 0.5  { mult = 2 }
        else                   { mult = 3 }

        var dy: Int32 = 0
        var dx: Int32 = 0
        // Sign convention (verified empirically on macOS):
        // wheel1 positive → scroll up (view reveals content above)
        // wheel2 positive → scroll left (view reveals content to the left)
        if activeScrollDirections.contains(.up)    { dy += scrollPixelsPerTick * mult }
        if activeScrollDirections.contains(.down)  { dy -= scrollPixelsPerTick * mult }
        if activeScrollDirections.contains(.left)  { dx += scrollPixelsPerTick * mult }
        if activeScrollDirections.contains(.right) { dx -= scrollPixelsPerTick * mult }

        postScrollEvent(deltaY: dy, deltaX: dx)
    }

    private func postScrollEvent(deltaY: Int32, deltaX: Int32) {
        // .pixel units are the most widely-supported scroll format across
        // native AppKit, Electron, web browsers, and Terminal. .line units
        // work in many native apps but silently no-op in some Electron apps.
        //
        // We post BOTH a wheelCount:2 pixel event (carries dx and dy) AND
        // explicitly set the "fixed point" delta fields, which some apps
        // (notably Chromium-based browsers) read instead of the wheel deltas.
        let needsHorizontal = deltaX != 0
        let wheelCount: UInt32 = needsHorizontal ? 2 : 1
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: wheelCount,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }
        // Explicit fixed-point delta — some apps prefer these fields.
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        if needsHorizontal {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX))
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Movement timer

    private func startTimerIfNeeded() {
        guard moveTimer == nil else { return }
        let interval = 1.0 / tickRate
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        moveTimer = timer
    }

    private func stopTimer() {
        moveTimer?.cancel()
        moveTimer = nil
        tickAccumX = 0
        tickAccumY = 0
        movementStartedAt = nil
    }

    private func tick() {
        guard !activeDirections.isEmpty else { stopTimer(); return }

        var dx: Double = 0
        var dy: Double = 0
        let step = pixelsPerTickBase * accelMultiplier() * boostMultiplier

        if activeDirections.contains(.up)    { dy -= step }
        if activeDirections.contains(.down)  { dy += step }
        if activeDirections.contains(.left)  { dx -= step }
        if activeDirections.contains(.right) { dx += step }

        // Diagonal normalization → consistent magnitude on all 8 directions.
        if dx != 0 && dy != 0 {
            let factor = 1.0 / sqrt(2.0)
            dx *= factor
            dy *= factor
        }

        tickAccumX += dx
        tickAccumY += dy
        let moveX = tickAccumX.rounded(.towardZero)
        let moveY = tickAccumY.rounded(.towardZero)
        tickAccumX -= moveX
        tickAccumY -= moveY
        if moveX == 0 && moveY == 0 { return }

        let current = realCursorPosition()
        let next = CGPoint(x: current.x + moveX, y: current.y + moveY)
        let clamped = clampToDisplays(next, current: current)

        // Warp the real cursor every tick. CGWarpMouseCursorPosition moves the
        // cursor visually, but in some tracking contexts (notably NSMenu /
        // right-click context menus, which use SkyLight-level event tracking)
        // the implicit mouseMoved it generates isn't seen. Symptom: hovering
        // over menu items via keys doesn't highlight them.
        //
        // Fix: post an explicit `.mouseMoved` CGEvent at the new position via
        // .cghidEventTap. This is dispatched as if it were a real hardware
        // move and triggers hover highlighting in NSMenu, AppKit/Electron
        // tooltips, link previews, etc.
        CGWarpMouseCursorPosition(clamped)
        if isDragging {
            // During drag, the matching dragged event must follow each move
            // — apps render selection rectangles from THIS stream, not from
            // mouseMoved. clickCount=1 keeps the drag continuous.
            postMouseEvent(.leftMouseDragged, at: clamped, button: .left, clickCount: 1)
        } else {
            postMouseEvent(.mouseMoved, at: clamped, button: .left, clickCount: 0)
        }
    }

    // MARK: - Position helpers

    private func realCursorPosition() -> CGPoint {
        // CGEvent path is preferred (matches the coord space used by every
        // other CGEvent call in this file). Fall back to NSEvent — which
        // also reports current cursor position — if CGEvent allocation fails.
        // Falling back to .zero would silently warp the cursor to the top-left.
        if let p = CGEvent(source: nil)?.location { return p }
        let ns = NSEvent.mouseLocation
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: ns.x, y: primaryHeight - ns.y)
    }

    private func clampToDisplays(_ point: CGPoint, current: CGPoint) -> CGPoint {
        let displays = cachedDisplayBounds
        guard !displays.isEmpty else { return point }
        for bounds in displays where bounds.contains(point) {
            return point
        }
        let active = displays.first(where: { $0.contains(current) }) ?? displays[0]
        return CGPoint(
            x: max(active.minX, min(active.maxX - 1, point.x)),
            y: max(active.minY, min(active.maxY - 1, point.y))
        )
    }

    private func refreshDisplayCache() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else {
            cachedDisplayBounds = [CGDisplayBounds(CGMainDisplayID())]
            return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        cachedDisplayBounds = ids.map { CGDisplayBounds($0) }
    }

    private func postMouseEvent(_ type: CGEventType,
                                at point: CGPoint,
                                button: CGMouseButton,
                                clickCount: Int64) {
        guard let event = CGEvent(mouseEventSource: nil,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
    }
}
