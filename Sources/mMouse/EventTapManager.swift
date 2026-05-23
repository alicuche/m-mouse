import AppKit
import Carbon
import CoreGraphics
import Foundation

/// C-style free function bridge for CGEventTap callback (cannot capture context).
/// `userInfo` is a retained Unmanaged pointer to EventTapManager; lifetime tied
/// to the tap (released in `teardownTap`).
private func mMouseEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handle(proxy: proxy, type: type, event: event)
}

/// Modifier bits used to detect "no modifier held" (for `none` activation modifier).
private let relevantModifierMask: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift,
]

/// Activation/lockdown invariants assume the CGEventTap callback runs on the
/// MAIN thread (the source is added to `CFRunLoopGetMain()`). All mutable state
/// in this class is touched only from main and is therefore race-free without
/// explicit locks. Assertions in hot paths verify the invariant in debug builds.
final class EventTapManager: @unchecked Sendable {

    // MARK: - Public

    private(set) var isActive: Bool = false {
        didSet {
            guard oldValue != isActive else { return }
            // We only ever mutate isActive on main (callback runs on main RunLoop,
            // menu actions are @MainActor). assumeIsolated lets us call the
            // @MainActor closure synchronously without an async hop.
            let active = isActive
            MainActor.assumeIsolated {
                onActivationChange?(active)
            }
        }
    }
    /// Always invoked on the main thread (callback fires on main RunLoop).
    /// Typed `@MainActor` so observers can update UI without async hops.
    var onActivationChange: (@MainActor (Bool) -> Void)?

    /// Fired right after a click / right-click / drag-start / drag-end
    /// commits. Used by UI indicators (menu bar icon, badge) to flash a
    /// confirmation. Always invoked on the main thread.
    var onActionFire: (@MainActor () -> Void)?

    var config: AppConfig {
        didSet {
            // CRITICAL: if active mode is running with keys held, the OLD
            // keycodes are still in heldMovement/heldScroll. After rebuild,
            // the keyUp lookup uses NEW keycodes — old held keys would never
            // release → leaked timer. Force-release before rebuild. Also end
            // any in-progress drag so apps don't see a hanging mouseDown.
            //
            // Order matters: clear our keycode bookkeeping FIRST, then ask
            // MouseController to stop its timers — otherwise a keyUp event
            // dispatched on the same main RunLoop between the two could see
            // a stale entry.
            if isActive {
                cleanupDragIfNeeded()
                heldMovement.removeAll()
                heldScroll.removeAll()
                mouseController.releaseAll()
                mouseController.stopScroll()
            }
            rebuildKeyTables()
        }
    }

    private let mouseController: MouseController
    private let badge: CursorBadge

    init(config: AppConfig, mouseController: MouseController, badge: CursorBadge) {
        self.config = config
        self.mouseController = mouseController
        self.badge = badge
        rebuildKeyTables()
    }

    deinit {
        teardownTap()
        healthTimer?.cancel()
        badgeFollowTimer?.cancel()
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Badge follow timer
    //
    // 60Hz polling timer reads the current cursor position and updates the
    // badge to follow it. Runs ONLY while active mode is on. Polling beats
    // subscribing to mouseMoved events because it also catches our own warps
    // (which generate mouseMoved but might race with the badge update), and
    // because adding mouseMoved to the tap mask would invite consume bugs.

    private var badgeFollowTimer: DispatchSourceTimer?

    private func startBadgeFollowTimer() {
        badgeFollowTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let pos = self.currentCursorPosition()
            MainActor.assumeIsolated { self.badge.move(to: pos) }
        }
        timer.resume()
        badgeFollowTimer = timer
    }

    private func stopBadgeFollowTimer() {
        badgeFollowTimer?.cancel()
        badgeFollowTimer = nil
    }

    /// Read current cursor position. Mirrors MouseController.realCursorPosition
    /// but kept local so EventTapManager doesn't depend on a private API.
    private func currentCursorPosition() -> CGPoint {
        if let p = CGEvent(source: nil)?.location { return p }
        let ns = NSEvent.mouseLocation
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: ns.x, y: primaryHeight - ns.y)
    }

    // MARK: - Tap lifecycle

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: DispatchSourceTimer?
    /// Retained `Unmanaged` pointer stored in the tap's userInfo; released in `teardownTap`.
    private var retainedSelfPtr: UnsafeMutableRawPointer?

    @discardableResult
    func start() -> Bool {
        assert(Thread.isMainThread, "EventTapManager.start must run on main")
        // If we're recreating the tap while a drag is in progress (e.g. health
        // timer recovery, sleep/wake), commit the mouseUp BEFORE tearing down —
        // otherwise the foreground app sees a permanent mouseDown that never
        // resolves until next click.
        cleanupDragIfNeeded()
        teardownTap()

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mMouseEventTapCallback,
            userInfo: selfPtr
        ) else {
            // tapCreate failed — release the pointer we just retained.
            Unmanaged<EventTapManager>.fromOpaque(selfPtr).release()
            print("[mMouse] Failed to create event tap. Accessibility permission missing?")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.retainedSelfPtr = selfPtr
        self.eventTap = tap
        self.runLoopSource = source

        startHealthTimer()
        registerWakeNotification()
        print("[mMouse] Event tap started")
        return true
    }

    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        if let ptr = retainedSelfPtr {
            Unmanaged<EventTapManager>.fromOpaque(ptr).release()
            retainedSelfPtr = nil
        }
    }

    private func startHealthTimer() {
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                print("[mMouse] Tap disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    print("[mMouse] Re-enable failed — recreating tap")
                    // Break the re-entrant call stack: timer event handler →
                    // start() → teardownTap() would otherwise tear down the
                    // very timer currently executing. Async hop ensures the
                    // handler returns first.
                    DispatchQueue.main.async { [weak self] in _ = self?.start() }
                }
            }
        }
        timer.resume()
        healthTimer = timer
    }

    private var wakeObserver: NSObjectProtocol?
    private func registerWakeNotification() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[mMouse] System woke — restarting tap")
            _ = self?.start()
        }
    }

    // MARK: - Hardcoded click / control keys

    private let enterKeyCode: CGKeyCode = CGKeyCode(kVK_Return)
    private let keypadEnterKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_KeypadEnter)
    private let escapeKeyCode: CGKeyCode = CGKeyCode(kVK_Escape)
    private let doubleClickWindowMs: Double = 400

    // MARK: - Cached key tables (rebuilt on config change)

    /// Sentinel for "unmapped". CGKeyCode 0 is `kVK_ANSI_A`, so we use UInt16.max
    /// which never matches a real keycode.
    private static let unmappedKey: CGKeyCode = CGKeyCode.max

    private struct CachedKeys {
        var activationModifier: CGEventFlags = []
        var activationKeyCode: CGKeyCode = EventTapManager.unmappedKey
        var activationRepeatCount: Int = 2
        var activationWindowMs: Int = 500
        var upKey: CGKeyCode = EventTapManager.unmappedKey
        var downKey: CGKeyCode = EventTapManager.unmappedKey
        var leftKey: CGKeyCode = EventTapManager.unmappedKey
        var rightKey: CGKeyCode = EventTapManager.unmappedKey
        var boostModifier: CGEventFlags = []
        var boostMultiplier: Double = 1.0
    }
    private var keys = CachedKeys()
    private var movementKeyCodes: Set<CGKeyCode> = []

    private func rebuildKeyTables() {
        assert(Thread.isMainThread, "rebuildKeyTables must run on main")
        let c = config

        func resolveKey(_ name: String, role: String) -> CGKeyCode {
            if let kc = KeyMapping.keyCode(for: name) {
                return kc
            }
            print("[mMouse] WARNING: Unknown key '\(name)' for \(role) — binding disabled")
            return EventTapManager.unmappedKey
        }

        var activationDisarmed = false
        if let mod = KeyMapping.modifierFlag(for: c.activationCombo.modifier) {
            keys.activationModifier = mod
        } else {
            print("[mMouse] WARNING: Unknown modifier '\(c.activationCombo.modifier)' — activation combo DISARMED")
            keys.activationModifier = []
            activationDisarmed = true
        }
        keys.activationKeyCode = activationDisarmed
            ? EventTapManager.unmappedKey
            : resolveKey(c.activationCombo.key, role: "activation combo key")
        keys.activationRepeatCount = max(1, c.activationCombo.repeatCount)
        keys.activationWindowMs    = max(50, c.activationCombo.windowMs)

        // Foot-gun guard: activation key must not collide with Enter — the
        // active-mode click handler would never see Enter because the activation
        // check runs first and would consume every press.
        if keys.activationKeyCode == enterKeyCode || keys.activationKeyCode == keypadEnterKeyCode {
            print("[mMouse] WARNING: activation key collides with Enter (used for click) — DISARMING activation. Choose a different key.")
            keys.activationKeyCode = EventTapManager.unmappedKey
        }
        keys.upKey    = resolveKey(c.keys.up,    role: "keys.up")
        keys.downKey  = resolveKey(c.keys.down,  role: "keys.down")
        keys.leftKey  = resolveKey(c.keys.left,  role: "keys.left")
        keys.rightKey = resolveKey(c.keys.right, role: "keys.right")

        movementKeyCodes = Set([keys.upKey, keys.downKey, keys.leftKey, keys.rightKey]
            .filter { $0 != EventTapManager.unmappedKey })

        // Speed boost modifier (e.g. Option held + arrow = 5× speed)
        if let mod = KeyMapping.modifierFlag(for: c.speedBoost.modifier) {
            keys.boostModifier = mod
        } else {
            print("[mMouse] WARNING: Unknown speedBoost modifier '\(c.speedBoost.modifier)' — boost disabled")
            keys.boostModifier = []
        }
        keys.boostMultiplier = max(1.0, c.speedBoost.multiplier)

        // Foot-gun: Cmd is now hardcoded for scroll. If the user's boost
        // modifier collides with Cmd, boost will silently never fire because
        // the scroll branch in handle() short-circuits first. Warn so they
        // can pick a different modifier (Option works, as does any combo).
        if keys.boostModifier.contains(.maskCommand) {
            print("[mMouse] WARNING: speedBoost.modifier '\(c.speedBoost.modifier)' includes Command, which is hardcoded for scroll — boost will not fire. Pick a different modifier (e.g. 'option').")
        }
        // Same hazard if boost modifier matches Shift exactly (Shift = drag).
        if keys.boostModifier == .maskShift {
            print("[mMouse] WARNING: speedBoost.modifier 'shift' collides with the hardcoded drag trigger — boost will not fire. Pick a different modifier.")
        }

        // Foot-gun guard: with a `none` modifier, an activation key that also
        // appears in movement keys would consume every press of that key,
        // making the movement direction unreachable in active mode.
        if keys.activationModifier.isEmpty,
           keys.activationKeyCode != EventTapManager.unmappedKey,
           movementKeyCodes.contains(keys.activationKeyCode) {
            print("[mMouse] WARNING: activation key collides with a movement key under 'none' modifier — DISARMING activation. Add a modifier or change the key.")
            keys.activationKeyCode = EventTapManager.unmappedKey
        }

        mouseController.speedLevel = c.speed
    }

    // MARK: - Activation state machine

    private var activationPressCount: Int = 0
    private var activationResetWork: DispatchWorkItem?

    private func handleActivationCandidate(modifierMatches: Bool, keyCodeMatches: Bool, isRepeat: Bool) -> Bool {
        guard modifierMatches && keyCodeMatches && !isRepeat else { return false }
        guard keys.activationKeyCode != EventTapManager.unmappedKey else { return false }
        activationPressCount += 1
        scheduleActivationReset()
        print("[mMouse] activation press #\(activationPressCount)/\(keys.activationRepeatCount)")
        if activationPressCount >= keys.activationRepeatCount {
            activationPressCount = 0
            activationResetWork?.cancel()
            activationResetWork = nil
            toggleActivation()
        }
        return true
    }

    private func scheduleActivationReset() {
        activationResetWork?.cancel()
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            // Identity guard: a cancelled work item that was already dequeued
            // can still fire — bail if a newer scheduling has replaced us.
            guard let self = self, self.activationResetWork === work else { return }
            self.activationPressCount = 0
            self.activationResetWork = nil
        }
        activationResetWork = work
        let delay = Double(keys.activationWindowMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func toggleActivation() {
        isActive.toggle()
        if isActive {
            // Show the small follow-badge anchored to the current cursor pos,
            // then keep it in sync with cursor moves via the 60Hz timer.
            let pos = currentCursorPosition()
            MainActor.assumeIsolated { badge.show(at: pos) }
            startBadgeFollowTimer()
            // Reset the flag snapshot so Option-release detection compares
            // against an empty baseline (the very first flagsChanged after
            // activation will set this for subsequent comparisons).
            lastObservedFlags = []
        } else {
            // If still dragging when deactivating, commit the mouseUp first
            // so apps don't get stuck with a pending button-down event.
            cleanupDragIfNeeded()
            mouseController.releaseAll()
            heldMovement.removeAll()
            mouseController.setBoost(1.0)
            stopBadgeFollowTimer()
            MainActor.assumeIsolated { badge.hide() }
        }
        enterClickCount = 0
        enterClickResetWork?.cancel()
        enterClickResetWork = nil
        heldScroll.removeAll()
        mouseController.stopScroll()
        print("[mMouse] mMouse mode: \(isActive ? "ACTIVE" : "inactive")")
    }

    // MARK: - Drag mode (Shift-hold)
    //
    // Hold Shift + arrow → mouseDown on first movement, drag while Shift held,
    // mouseUp when Shift is released. Screenshot-tool / lasso-select style.
    //
    // dragSource currently has just one non-.none case (.shiftHold) but is
    // kept as an enum to leave room for additional drag triggers without
    // refactoring the exitDragMode source-matching logic.

    private enum DragSource { case none, shiftHold }
    private var dragSource: DragSource = .none

    /// Snapshot of flags from the previous keyboard/flagsChanged event.
    /// Used to detect "Shift was just released" by comparing prev vs current.
    private var lastObservedFlags: CGEventFlags = []

    private func enterDragMode(source: DragSource) {
        guard !mouseController.isDragging else { return }
        mouseController.startDrag()
        dragSource = source
        fireActionIndicators()
    }

    /// End drag. If `forSource` is set, only ends if the current drag was
    /// started by that source — leaves room for future drag triggers to
    /// coexist without ending each other prematurely.
    private func exitDragMode(forSource source: DragSource? = nil) {
        guard mouseController.isDragging else { return }
        if let req = source, req != dragSource { return }
        mouseController.endDrag()
        dragSource = .none
        fireActionIndicators()
    }

    /// Flash every UI indicator hooked up to onActionFire (menu bar icon)
    /// plus the cursor badge. Centralized so all action sites stay in
    /// lockstep — adding a new indicator only needs one new subscriber.
    private func fireActionIndicators() {
        MainActor.assumeIsolated {
            badge.flashAction()
            onActionFire?()
        }
    }

    /// Safety net for code paths that destroy or rebuild the tap (sleep/wake,
    /// tap recreate, config hot-reload). If a drag is in progress, post the
    /// mouseUp NOW so the foreground app doesn't get stuck with a phantom
    /// button-down event. Idempotent — safe to call when not dragging.
    private func cleanupDragIfNeeded() {
        guard mouseController.isDragging else { return }
        mouseController.endDrag()
        dragSource = .none
    }

    private func updateBoostFromFlags(_ flags: CGEventFlags) {
        guard !keys.boostModifier.isEmpty else {
            mouseController.setBoost(1.0)
            return
        }
        let boostOn = flags.intersection(keys.boostModifier) == keys.boostModifier
        mouseController.setBoost(boostOn ? keys.boostMultiplier : 1.0)
    }

    // MARK: - Movement key tracking

    private var heldMovement: Set<CGKeyCode> = []

    // MARK: - Enter click counter

    private var enterClickCount: Int = 0
    private var enterClickResetWork: DispatchWorkItem?

    private func handleEnterClick() {
        enterClickCount += 1
        enterClickResetWork?.cancel()
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            // Identity guard against already-dequeued cancelled item firing.
            guard let self = self, self.enterClickResetWork === work else { return }
            self.enterClickCount = 0
            self.enterClickResetWork = nil
        }
        enterClickResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickWindowMs / 1000.0, execute: work)

        // Matches a real mouse double-click: first event count=1 fires, second
        // event count=2 fires. Native AppKit/UIKit apps recognize this as a
        // double-click via NSEvent.clickCount; the count=1 side-effect (caret
        // placement, etc.) is intentional and matches OS behavior.
        let count = min(enterClickCount, 2)
        mouseController.click(count: count)
        fireActionIndicators()
    }

    private func handleRightClick() {
        mouseController.rightClick()
        fireActionIndicators()
    }

    // MARK: - Core callback

    fileprivate func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Invariant: callback runs on main thread (source attached to main RunLoop).
        assert(Thread.isMainThread, "CGEventTap callback expected on main thread")

        // Dual strategy: re-enable inline (fast) AND in healthTimer (covers
        // edge cases where the disable notification doesn't fire — e.g. tap
        // killed during sleep). Don't "simplify" by removing either path.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // flagsChanged: always pass through so apps see modifier state changes.
        // Also tracks boost modifier so a held Cmd multiplies movement speed,
        // and ends a Shift-held drag the moment the user releases Shift.
        if type == .flagsChanged {
            if isActive {
                let prevShift = lastObservedFlags.contains(.maskShift)
                let currShift = event.flags.contains(.maskShift)
                if prevShift && !currShift && dragSource == .shiftHold {
                    exitDragMode(forSource: .shiftHold)
                }
                updateBoostFromFlags(event.flags)
            }
            lastObservedFlags = event.flags
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags

        // --- Activation sequence detection (always armed, regardless of active state) ---
        if type == .keyDown {
            // Exact match on the relevant modifier subset. Cmd+Shift+Right
            // only matches when EXACTLY Cmd+Shift are held — extra modifiers
            // (e.g. accidentally also holding Option) won't trigger activation.
            let actualMods = flags.intersection(relevantModifierMask)
            let modMatch = actualMods == keys.activationModifier
            let keyMatch = keyCode == keys.activationKeyCode
            if handleActivationCandidate(modifierMatches: modMatch, keyCodeMatches: keyMatch, isRepeat: isRepeat) {
                return nil
            }
        }

        guard isActive else {
            return Unmanaged.passUnretained(event)
        }

        // --- ACTIVE MODE: full keyboard lockdown ---

        // Hardcoded panic deactivate: Esc always exits active mode.
        // (toggleActivation handles ending an in-progress drag automatically.)
        if keyCode == escapeKeyCode {
            if type == .keyDown && !isRepeat {
                print("[mMouse] Esc pressed — deactivating")
                toggleActivation()
            }
            return nil
        }

        if movementKeyCodes.contains(keyCode) {
            // On keyUp, ALWAYS release from whichever bucket holds the key —
            // regardless of current modifier state. This prevents stuck
            // timers when the user toggles a modifier mid-hold (e.g. press j
            // → press option → release j: keyUp arrives with Option held but
            // j is in heldMovement, not heldScroll).
            if type == .keyUp {
                releaseMovementOrScroll(keyCode: keyCode)
                return nil
            }
            // keyDown: Shift + movement = hold-to-drag (screenshot-tool style).
            // The drag is committed when Shift is released (see the
            // flagsChanged handler). Start it on the first movement if not
            // already dragging.
            if flags.contains(.maskShift) && !mouseController.isDragging {
                enterDragMode(source: .shiftHold)
            }
            // Cmd + movement = SCROLL at cursor. Suppressed while dragging
            // so a Shift+Cmd+arrow combo doesn't try to scroll on top of
            // the in-progress drag.
            if flags.contains(.maskCommand) && !mouseController.isDragging {
                handleScrollKey(keyCode: keyCode, type: type, isRepeat: isRepeat)
                return nil
            }
            // Re-evaluate boost from current flags — covers the case where
            // the modifier was already held before the first movement keyDown
            // (no flagsChanged fires for that).
            updateBoostFromFlags(flags)
            handleMovementKey(keyCode: keyCode, type: type, isRepeat: isRepeat)
            return nil
        }

        if keyCode == enterKeyCode || keyCode == keypadEnterKeyCode {
            if type == .keyDown && !isRepeat {
                // During drag, Enter commits the drag (mouseUp). No regular
                // click semantics — would corrupt the drag state.
                if mouseController.isDragging {
                    exitDragMode()
                } else if flags.contains(.maskShift) {
                    handleRightClick()
                } else {
                    handleEnterClick()
                }
            }
            return nil
        }

        // PRIORITY MODEL: mMouse's own keys (arrows, Enter, Esc, activation)
        // are claimed above. Everything else — typing, system shortcuts
        // (Cmd+C/V/Q/Tab, Cmd+Shift+4, etc.) — passes through to the
        // foreground app as if mMouse weren't active. No more whitelist.
        return Unmanaged.passUnretained(event)
    }

    private func handleMovementKey(keyCode: CGKeyCode, type: CGEventType, isRepeat: Bool) {
        let direction: MouseController.Direction
        switch keyCode {
        case keys.upKey:    direction = .up
        case keys.downKey:  direction = .down
        case keys.leftKey:  direction = .left
        case keys.rightKey: direction = .right
        default: return
        }

        if type == .keyDown {
            if isRepeat { return }
            // Symmetric to handleScrollKey: if the key was scrolling (no shift
            // now), cancel that bucket first.
            if heldScroll.remove(keyCode) != nil {
                mouseController.releaseScroll(direction)
            }
            if heldMovement.insert(keyCode).inserted {
                mouseController.press(direction)
            }
        } else if type == .keyUp {
            if heldMovement.remove(keyCode) != nil {
                mouseController.release(direction)
            }
        }
    }

    /// Direction for a movement keycode, or nil if unmapped. Used by keyUp
    /// fallback so we can release whichever bucket held the key.
    private func directionForMovementKey(_ keyCode: CGKeyCode) -> MouseController.Direction? {
        switch keyCode {
        case keys.upKey:    return .up
        case keys.downKey:  return .down
        case keys.leftKey:  return .left
        case keys.rightKey: return .right
        default: return nil
        }
    }

    /// Release the keycode from movement OR scroll bucket — whichever it lives in.
    /// Called from keyUp regardless of current modifier flags so toggling Shift
    /// mid-hold never leaks a running timer.
    private func releaseMovementOrScroll(keyCode: CGKeyCode) {
        guard let direction = directionForMovementKey(keyCode) else { return }
        if heldMovement.remove(keyCode) != nil {
            mouseController.release(direction)
        }
        if heldScroll.remove(keyCode) != nil {
            mouseController.releaseScroll(direction)
        }
    }

    // MARK: - Scroll key tracking

    private var heldScroll: Set<CGKeyCode> = []

    /// Invoked ONLY for keyDown — keyUp of movement keys is intercepted by
    /// `releaseMovementOrScroll` in the main callback regardless of Shift state.
    private func handleScrollKey(keyCode: CGKeyCode, type: CGEventType, isRepeat: Bool) {
        assert(type == .keyDown, "handleScrollKey called with non-keyDown type; release path is in main callback")
        guard let direction = directionForMovementKey(keyCode) else { return }
        if isRepeat { return }
        // If user was moving this direction (no shift), then pressed shift,
        // cancel the movement first so the same key doesn't double-fire.
        if heldMovement.remove(keyCode) != nil {
            mouseController.release(direction)
        }
        if heldScroll.insert(keyCode).inserted {
            mouseController.pressScroll(direction)
        }
    }

    // MARK: - External control (menu bar)

    func forceDeactivate() {
        assert(Thread.isMainThread)
        if isActive {
            toggleActivation()
            return
        }
        // Defensive: if state ever drifts so a drag is on but isActive is
        // false (shouldn't happen via normal flow, but a future refactor or
        // unexpected event order could), still post the mouseUp so the app
        // doesn't get stuck.
        cleanupDragIfNeeded()
    }

    func activateFromMenu() {
        assert(Thread.isMainThread)
        if !isActive { toggleActivation() }
    }
}
