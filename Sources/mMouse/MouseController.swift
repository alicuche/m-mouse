import AppKit
import CoreGraphics
import Foundation

final class MouseController: @unchecked Sendable {
    private var moveTimer: DispatchSourceTimer?
    private var activeDirections: Set<Direction> = []
    private var tickAccumX: Double = 0
    private var tickAccumY: Double = 0

    /// The "aim" position. Driven by movement keys (NOT the real cursor —
    /// the real cursor stays parked so hover effects don't fire while aiming).
    /// Real cursor is only warped to this position when a click commits.
    private var aimPosition: CGPoint?

    /// Called every tick the aim position changes. Used by CursorOverlay
    /// to render the floating aim icon. Always invoked on main thread.
    var onAimChanged: (@MainActor (CGPoint) -> Void)?

    /// Current aim position, or nil if no movement burst is active.
    var currentAim: CGPoint? { aimPosition }

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

    /// Speed level 1..10 (clamped). 1 = chậm, 10 = nhanh nhất.
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
            // Don't sync to real cursor — aim was set explicitly by overlay
            // (e.g., centerAim called on activation). Just start ticking.
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

    /// Sets the aim to the center of the display containing the real cursor
    /// (or the main display if no display matches). Used on activation so
    /// the user has a predictable starting point. Does NOT move the real
    /// cursor — only the aim/overlay position.
    func centerAimOnCurrentDisplay() {
        let current = realCursorPosition()
        let displays = cachedDisplayBounds.isEmpty ? [CGDisplayBounds(CGMainDisplayID())] : cachedDisplayBounds
        let active = displays.first(where: { $0.contains(current) }) ?? displays[0]
        let center = CGPoint(x: active.midX, y: active.midY)
        setAim(center)
    }

    // MARK: - Click actions

    /// Post a left click at the current aim position (warping the real
    /// cursor there first). `count=1` → single click. `count=2` after a
    /// count=1 registers as double-click.
    func click(count: Int = 1) {
        let pos = warpToAim()
        let clamped = max(1, min(3, count))
        postMouseEvent(.leftMouseDown, at: pos, button: .left, clickCount: Int64(clamped))
        postMouseEvent(.leftMouseUp,   at: pos, button: .left, clickCount: Int64(clamped))
    }

    func rightClick() {
        let pos = warpToAim()
        postMouseEvent(.rightMouseDown, at: pos, button: .right, clickCount: 1)
        postMouseEvent(.rightMouseUp,   at: pos, button: .right, clickCount: 1)
    }

    // MARK: - Scroll

    private var scrollTimer: DispatchSourceTimer?
    private var activeScrollDirections: Set<Direction> = []
    private var scrollStartedAt: TimeInterval?

    /// Lines per scroll tick (line-based scrolling — most apps map 1 line ≈ one
    /// notch of a wheel mouse). Held longer = small acceleration ramp.
    private let scrollTickRate: Double = 30 // 30 ticks/sec
    private let scrollLinesPerTick: Int32 = 1

    func pressScroll(_ direction: Direction) {
        if activeScrollDirections.isEmpty {
            // Warp real cursor to aim once — subsequent scrolls re-use that
            // position. Scroll events are dispatched at the cursor location.
            _ = warpRealCursorToAim()
            scrollStartedAt = CACurrentMediaTime()
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
        if activeScrollDirections.contains(.up)    { dy += scrollLinesPerTick * mult }
        if activeScrollDirections.contains(.down)  { dy -= scrollLinesPerTick * mult }
        if activeScrollDirections.contains(.right) { dx -= scrollLinesPerTick * mult }
        if activeScrollDirections.contains(.left)  { dx += scrollLinesPerTick * mult }

        postScrollEvent(deltaY: dy, deltaX: dx)
    }

    /// Warp the real cursor to the aim (without firing onClickCommit, since
    /// this isn't a click — used by scroll to position before posting wheel events).
    @discardableResult
    private func warpRealCursorToAim() -> CGPoint {
        let target = aimPosition ?? realCursorPosition()
        CGWarpMouseCursorPosition(target)
        return target
    }

    private func postScrollEvent(deltaY: Int32, deltaX: Int32) {
        // unit=.line → integer line count, matches normal wheel-mouse semantics
        // (Smooth scroll apps still get reasonable values; coarse-grain apps
        // like terminals scroll a line at a time as expected.)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Called after a successful click — used by overlay to flash visual feedback.
    var onClickCommit: (@MainActor () -> Void)?

    /// Warp the real cursor to the current aim (or fall back to real cursor
    /// position if no aim set). Returns the position used.
    @discardableResult
    private func warpToAim() -> CGPoint {
        let target = aimPosition ?? realCursorPosition()
        CGWarpMouseCursorPosition(target)
        if let cb = onClickCommit {
            MainActor.assumeIsolated { cb() }
        }
        return target
    }

    /// Sets the aim position explicitly (used by EventTapManager to center
    /// the overlay on activation, or to sync with real cursor manually).
    func setAim(_ point: CGPoint) {
        aimPosition = point
        if let cb = onAimChanged {
            MainActor.assumeIsolated { cb(point) }
        }
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
        // Keep aimPosition — user might click after stopping movement.
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

        let current = aimPosition ?? realCursorPosition()
        let next = CGPoint(x: current.x + moveX, y: current.y + moveY)
        let clamped = clampToDisplays(next, current: current)
        aimPosition = clamped
        // Tick fires on DispatchSource main queue → safe to call MainActor closure.
        if let cb = onAimChanged {
            MainActor.assumeIsolated { cb(clamped) }
        }
        // NOTE: real cursor is NOT moved here. Overlay-only aiming.
    }

    // MARK: - Position helpers

    private func realCursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
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
