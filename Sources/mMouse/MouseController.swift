import AppKit
import CoreGraphics
import Foundation

final class MouseController: @unchecked Sendable {
    private var moveTimer: DispatchSourceTimer?
    private var activeDirections: Set<Direction> = []
    private var tickAccumX: Double = 0
    private var tickAccumY: Double = 0

    /// Locally tracked cursor position to avoid per-tick CGEvent allocation
    /// and software-vs-hardware cursor lag. Resynced to the real cursor
    /// position whenever movement starts from a stopped state.
    private var ownedCursorPos: CGPoint?

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
    }

    // MARK: - Direction press/release

    func press(_ direction: Direction) {
        if activeDirections.isEmpty {
            // Sync internal position with the real cursor when we start moving
            // (user may have moved the mouse manually since last session).
            ownedCursorPos = realCursorPosition()
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

    /// Post a left click. `count=1` → single click. `count=2` after a count=1
    /// makes apps recognize a double-click (matches real mouse behavior).
    func click(count: Int = 1) {
        let pos = ownedCursorPos ?? realCursorPosition()
        let clamped = max(1, min(3, count))
        postMouseEvent(.leftMouseDown, at: pos, button: .left, clickCount: Int64(clamped))
        postMouseEvent(.leftMouseUp,   at: pos, button: .left, clickCount: Int64(clamped))
    }

    func rightClick() {
        let pos = ownedCursorPos ?? realCursorPosition()
        postMouseEvent(.rightMouseDown, at: pos, button: .right, clickCount: 1)
        postMouseEvent(.rightMouseUp,   at: pos, button: .right, clickCount: 1)
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
        ownedCursorPos = nil
        movementStartedAt = nil
    }

    private func tick() {
        guard !activeDirections.isEmpty else { stopTimer(); return }

        var dx: Double = 0
        var dy: Double = 0
        let step = pixelsPerTickBase * accelMultiplier()

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

        let current = ownedCursorPos ?? realCursorPosition()
        let next = CGPoint(x: current.x + moveX, y: current.y + moveY)
        let clamped = clampToDisplays(next, current: current)
        ownedCursorPos = clamped

        if let event = CGEvent(mouseEventSource: nil,
                               mouseType: .mouseMoved,
                               mouseCursorPosition: clamped,
                               mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
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
