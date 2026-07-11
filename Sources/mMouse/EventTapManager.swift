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
            disarmSpotRecording()
            rebuildKeyTables()
            // Re-show the grid layer if it's on so a changed targetCellPx (or a
            // display change) is picked up immediately.
            if gridShown {
                hideGrid()
                showGrid()
            }
        }
    }

    private let mouseController: MouseController
    private let badge: CursorBadge
    private let gridOverlay: GridOverlay

    init(config: AppConfig, mouseController: MouseController, badge: CursorBadge, gridOverlay: GridOverlay) {
        self.config = config
        self.mouseController = mouseController
        self.badge = badge
        self.gridOverlay = gridOverlay
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
            // Keep the grid "you are here" outline tracking the cursor.
            self.refreshCurrentCell()
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

        // Highest interception priority: tap at the HID level (where events
        // enter the window server) with head-insert placement. This puts mMouse
        // AHEAD of the system's own hotkey handling, so our activation / grid
        // combos (and every key we claim in active mode) win over OS defaults
        // like Spotlight, Cmd+Space, Cmd+Tab, etc. Fall back to the session-
        // level tap if the HID tap can't be created (some restricted contexts).
        func makeTap(at location: CGEventTapLocation) -> CFMachPort? {
            CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: mMouseEventTapCallback,
                userInfo: selfPtr
            )
        }

        let createdTap = makeTap(at: .cghidEventTap) ?? {
            print("[mMouse] HID-level tap unavailable — falling back to session tap")
            return makeTap(at: .cgSessionEventTap)
        }()

        guard let tap = createdTap else {
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
        // The grid layer is an independent NSPanel tied to active mode, NOT to
        // the tap — recreating the tap (health recovery, sleep/wake) must leave
        // it untouched so it survives across tap restarts while still active.
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
        var gridModifier: CGEventFlags = []
        var gridKeyCode: CGKeyCode = EventTapManager.unmappedKey
        /// Extra single-press activation combos (modifier + keycode).
        var extraActivations: [(modifier: CGEventFlags, keyCode: CGKeyCode)] = []
        /// Saved-spots: modifier held with a slot key to warp/record (default Cmd).
        var spotWarpModifier: CGEventFlags = [.maskCommand]
        /// Saved-spots: arm-record combo (modifier + keycode).
        var spotRecordModifier: CGEventFlags = []
        var spotRecordKeyCode: CGKeyCode = EventTapManager.unmappedKey
        var spotArmWindowMs: Int = 8000
    }
    private var keys = CachedKeys()
    private var movementKeyCodes: Set<CGKeyCode> = []

    /// keyCode → recorded warp target (CG, top-left origin). Rebuilt on config
    /// change from `config.savedSpots.spots`.
    private var spotsByKeyCode: [CGKeyCode: CGPoint] = [:]

    /// Persist a config mutation (a recorded saved-spot) back to disk + observers.
    /// Wired by AppDelegate to `ConfigManager.save`. Always called on main.
    var persistConfig: (@MainActor (AppConfig) -> Void)?

    /// keyCode → uppercase character (A–Z, 0–9), built once. Used to decode
    /// keys typed while the grid overlay is open — letters drive row/column
    /// jumps, and letters/digits together form custom labels (e.g. "S1", "11").
    private static let gridKeyChars: [CGKeyCode: Character] = {
        var map = [CGKeyCode: Character]()
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            if let kc = KeyMapping.keyCode(for: String(ch).lowercased()) { map[kc] = ch }
        }
        return map
    }()
    private let deleteKeyCode: CGKeyCode = CGKeyCode(kVK_Delete)

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

        // Grid-layer trigger (e.g. Cmd+' turns the labelled-matrix layer on on
        // top of red mode). Detected independently of the activation state
        // machine so it never shares the press counter / window timer.
        if let mod = KeyMapping.modifierFlag(for: c.grid.combo.modifier) {
            keys.gridModifier = mod
        } else {
            print("[mMouse] WARNING: Unknown grid combo modifier '\(c.grid.combo.modifier)' — grid layer DISARMED")
            keys.gridModifier = []
            keys.gridKeyCode = EventTapManager.unmappedKey
        }
        if keys.gridModifier.isEmpty && c.grid.combo.modifier.lowercased() != "none" {
            keys.gridKeyCode = EventTapManager.unmappedKey
        } else {
            keys.gridKeyCode = resolveKey(c.grid.combo.key, role: "grid combo key")
        }
        // Foot-gun guards: a grid key colliding with movement/Enter/Esc, a bare
        // letter (those drive jumps while the layer is on), or the activation
        // combo would be shadowed or hijack those keys.
        if keys.gridKeyCode != EventTapManager.unmappedKey {
            if keys.gridKeyCode == enterKeyCode || keys.gridKeyCode == keypadEnterKeyCode
                || keys.gridKeyCode == escapeKeyCode || movementKeyCodes.contains(keys.gridKeyCode) {
                print("[mMouse] WARNING: grid key collides with a reserved key (Enter/Esc/movement) — grid layer DISARMED. Pick a different key.")
                keys.gridKeyCode = EventTapManager.unmappedKey
            } else if keys.gridModifier == keys.activationModifier && keys.gridKeyCode == keys.activationKeyCode {
                print("[mMouse] WARNING: grid combo equals the activation combo — grid layer DISARMED. Use a different key/modifier.")
                keys.gridKeyCode = EventTapManager.unmappedKey
            }
        }

        // Extra activation combos (each a single-press toggle, e.g. Cmd+Q in
        // addition to the primary Cmd+E). Invalid entries are skipped with a
        // warning rather than disarming the whole list.
        keys.extraActivations = c.additionalActivationCombos.compactMap { combo in
            guard let mod = KeyMapping.modifierFlag(for: combo.modifier) else {
                print("[mMouse] WARNING: Unknown modifier '\(combo.modifier)' in additionalActivationCombos — skipped")
                return nil
            }
            if mod.isEmpty && combo.modifier.lowercased() != "none" { return nil }
            guard let kc = KeyMapping.keyCode(for: combo.key) else {
                print("[mMouse] WARNING: Unknown key '\(combo.key)' in additionalActivationCombos — skipped")
                return nil
            }
            return (modifier: mod, keyCode: kc)
        }

        // Saved spots: warpModifier+key warps to a recorded position; the
        // recordModifier+recordKey combo arms recording of the next slot.
        keys.spotWarpModifier   = KeyMapping.modifierFlag(for: c.savedSpots.warpModifier) ?? [.maskCommand]
        keys.spotRecordModifier = KeyMapping.modifierFlag(for: c.savedSpots.recordModifier) ?? []
        keys.spotRecordKeyCode  = KeyMapping.keyCode(for: c.savedSpots.recordKey) ?? EventTapManager.unmappedKey
        keys.spotArmWindowMs    = max(1000, c.savedSpots.armWindowMs)
        spotsByKeyCode = [:]
        for spot in c.savedSpots.spots {
            guard let kc = KeyMapping.keyCode(for: spot.key) else {
                print("[mMouse] WARNING: saved spot key '\(spot.key)' unknown — skipped")
                continue
            }
            spotsByKeyCode[kc] = CGPoint(x: spot.x, y: spot.y)
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
            activateBothLayers()
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

    /// Activation combos (Cmd+E / Cmd+Q) turn BOTH layers on — red mode AND the
    /// grid layer — and KEEP them on. Pressing the combo again while already
    /// active does NOT exit; it just re-ensures both layers are shown. So if
    /// Enter peeled the grid back to red-only, the combo re-opens the grid; if
    /// both are already up it's a no-op. Esc is the only full exit.
    private func activateBothLayers() {
        if !isActive { toggleActivation() }   // red mode on (badge + timer)
        if !gridShown { showGrid() }          // + grid layer on top
    }

    private func toggleActivation() {
        isActive.toggle()
        if isActive {
            // Red mode: show the follow-badge that tracks the cursor (60Hz
            // timer). The grid LAYER is a separate opt-in (Cmd+') on top of
            // this — it is NOT shown here.
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
            disarmSpotRecording()
            // Exiting red mode hides the grid layer too (if it was on).
            hideGrid()
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

    // MARK: - Grid layer (opt-in on top of red mode)
    //
    // Red mode (Cmd+E) gives you the follow-badge + arrows/click/scroll, and
    // bare letters still pass through (you can type). The grid LAYER (Cmd+')
    // sits on top: while it's on, bare/Shift letters JUMP the cursor to a cell
    // (row letter then column letter; Shift on the second also clicks), arrows
    // still nudge. The activation combo (Cmd+E/Cmd+Q) brings BOTH layers up and
    // keeps them up. Enter peels just the grid layer off (back to red-only);
    // Esc is the full exit, tearing down both layers at once.

    private var gridShown: Bool = false
    private var gridFirstChar: Character?   // first key typed in the current sequence
    private var gridRows: Int = 0
    private var gridCols: Int = 0
    private var gridDisplayBounds: CGRect = .zero
    private var gridCurrentCell: (row: Int, col: Int) = (-1, -1)
    private var gridResetWork: DispatchWorkItem?

    // Custom-label tables, rebuilt each time the grid is shown (they depend on
    // the matrix size). `gridCustomCells` feeds the overlay's green pills;
    // `gridCustomByLabel` / `gridCustomFirstChars` drive typed-key matching.
    private var gridCustomCells: [GridCell: String] = [:]
    private var gridCustomByLabel: [String: GridCell] = [:]
    private var gridCustomFirstChars: Set<Character> = []

    /// Turn the grid layer on (Cmd+'). Activates red mode first if needed, then
    /// shows the layer on top. Idempotent if the layer is already up.
    private func openLayer() {
        guard keys.gridKeyCode != EventTapManager.unmappedKey else { return }
        if !isActive { toggleActivation() }   // red mode on (badge + timer)
        if !gridShown { showGrid() }
    }

    /// Show the grid layer over the cursor's current display. Sizes the matrix
    /// so cells stay ~square (targetCellPx).
    private func showGrid() {
        let cursor = currentCursorPosition()
        let bounds = mouseController.displayBounds(containing: cursor)
        let cellW = max(60, config.grid.targetCellPx)
        let cellH = config.grid.targetCellHeightPx.map { max(30, $0) } ?? cellW
        gridDisplayBounds = bounds
        gridCols = max(1, min(26, Int((bounds.width / CGFloat(cellW)).rounded())))
        gridRows = max(1, min(26, Int((bounds.height / CGFloat(cellH)).rounded())))
        gridFirstChar = nil

        // Resolve custom labels for this matrix size (out-of-range cells drop).
        let custom = GridLabels.resolveCustom(config.grid.customLabels, rows: gridRows, cols: gridCols)
        gridCustomCells = custom
        var byLabel = [String: GridCell]()
        for (cell, label) in custom { byLabel[label] = cell }
        gridCustomByLabel = byLabel
        gridCustomFirstChars = Set(byLabel.keys.compactMap { $0.first })

        // Saved-spot shortcuts that fall on THIS display → show the warp combo
        // under the cell that contains each spot.
        var spotLabels = [GridCell: String]()
        let spotPrefix = EventTapManager.modifierSymbols(keys.spotWarpModifier)
        for (kc, point) in spotsByKeyCode {
            guard bounds.contains(point), let ch = EventTapManager.gridKeyChars[kc] else { continue }
            let (sr, sc) = cell(forCursor: point)
            guard sr >= 0 else { continue }
            spotLabels[GridCell(row: sr, col: sc)] = spotPrefix + String(ch)
        }

        let (curRow, curCol) = cell(forCursor: cursor)
        gridCurrentCell = (curRow, curCol)
        gridShown = true
        let rows = gridRows, cols = gridCols
        MainActor.assumeIsolated {
            gridOverlay.show(on: bounds, rows: rows, cols: cols, currentRow: curRow, currentCol: curCol,
                             customLabels: custom, spotLabels: spotLabels)
        }
        print("[mMouse] grid layer shown \(gridRows)x\(gridCols), \(custom.count) custom label(s)")
    }

    /// Hide the grid layer + reset its entry state. Leaves red mode untouched.
    /// Idempotent.
    private func hideGrid() {
        gridResetWork?.cancel()
        gridResetWork = nil
        gridFirstChar = nil
        gridCurrentCell = (-1, -1)
        guard gridShown else { return }
        gridShown = false
        MainActor.assumeIsolated { gridOverlay.hide() }
        print("[mMouse] grid layer hidden")
    }

    /// Grid cell (row, col) containing a cursor point. Clamped to the matrix.
    private func cell(forCursor cursor: CGPoint) -> (Int, Int) {
        guard gridCols > 0, gridRows > 0, gridDisplayBounds.width > 0 else { return (-1, -1) }
        let colW = gridDisplayBounds.width / CGFloat(gridCols)
        let rowH = gridDisplayBounds.height / CGFloat(gridRows)
        let col = min(gridCols - 1, max(0, Int((cursor.x - gridDisplayBounds.minX) / colW)))
        let row = min(gridRows - 1, max(0, Int((cursor.y - gridDisplayBounds.minY) / rowH)))
        return (row, col)
    }

    /// Keep the "you are here" outline in sync with the cursor (called from the
    /// follow timer). Cheap: GridOverlay only redraws when the cell changes.
    private func refreshCurrentCell() {
        guard isActive, gridShown else { return }
        let (row, col) = cell(forCursor: currentCursorPosition())
        guard row >= 0, (row, col) != gridCurrentCell else { return }
        gridCurrentCell = (row, col)
        MainActor.assumeIsolated { gridOverlay.updateCurrent(row: row, col: col) }
    }

    /// Handle a bare/Shift grid key (letter or custom-label digit) while the
    /// layer is on. A two-key sequence either completes a custom label (e.g.
    /// "S1", "11" → warp to a pinned cell) or a normal row+column code. The
    /// caller always consumes the key.
    private func handleGridKey(_ ch: Character, shiftHeld: Bool) {
        if let first = gridFirstChar {
            // Second key — try to complete a sequence.
            gridFirstChar = nil
            gridResetWork?.cancel(); gridResetWork = nil
            MainActor.assumeIsolated { gridOverlay.highlight(row: nil) }

            // A pinned custom label wins over the default row+column code.
            if let cell = gridCustomByLabel[String([first, ch])] {
                warpToCell(row: cell.row, col: cell.col, click: shiftHeld)
            } else if let row = gridRowIndex(of: first), let col = gridColIndex(of: ch) {
                warpToCell(row: row, col: col, click: shiftHeld)
            }
            // Anything else (e.g. an unfinished custom prefix) just resets.
            return
        }

        // First key: must start a custom label or pick a valid row, else ignore.
        let row = gridRowIndex(of: ch)
        guard gridCustomFirstChars.contains(ch) || row != nil else { return }
        gridFirstChar = ch
        if let row = row {
            MainActor.assumeIsolated { gridOverlay.highlight(row: row) }
        }
        scheduleGridReset()
    }

    /// Letter → row index, but only if it's a real row in this grid.
    private func gridRowIndex(of ch: Character) -> Int? {
        guard let i = GridLabels.letterIndex(ch), i < gridRows else { return nil }
        return i
    }

    /// Letter → column index, but only if it's a real column in this grid.
    private func gridColIndex(of ch: Character) -> Int? {
        guard let i = GridLabels.letterIndex(ch), i < gridCols else { return nil }
        return i
    }

    /// Warp the cursor to a cell's centre, peeling the row-dim, optionally
    /// clicking, and snapping the "you are here" outline to the landing cell.
    private func warpToCell(row: Int, col: Int, click: Bool) {
        let centre = MainActor.assumeIsolated { () -> CGPoint in
            gridOverlay.highlight(row: nil)        // un-dim, layer stays up
            return gridOverlay.cellCentre(row: row, col: col)
        }
        mouseController.warp(to: centre)
        if click {
            mouseController.click(count: 1)
            fireActionIndicators()
        }
        gridCurrentCell = (-1, -1)
        refreshCurrentCell()
    }

    /// Current cell, computing it from the live cursor position if it hasn't
    /// been resolved yet.
    private func ensureCurrentCell() -> (row: Int, col: Int) {
        if gridCurrentCell.row >= 0 { return gridCurrentCell }
        let cc = cell(forCursor: currentCursorPosition())
        gridCurrentCell = cc
        return cc
    }

    /// Arrow in layer mode = step the hover cell one cell in `direction` and
    /// warp the cursor to that cell's centre (discrete cell-to-cell jumps, not
    /// the slow continuous glide).
    private func gridArrowStep(_ direction: MouseController.Direction) {
        var (row, col) = ensureCurrentCell()
        switch direction {
        case .up:    row = max(0, row - 1)
        case .down:  row = min(gridRows - 1, row + 1)
        case .left:  col = max(0, col - 1)
        case .right: col = min(gridCols - 1, col + 1)
        }
        guard (row, col) != gridCurrentCell else { return }   // already at the edge
        gridCurrentCell = (row, col)
        let centre = MainActor.assumeIsolated { () -> CGPoint in
            gridOverlay.updateCurrent(row: row, col: col)
            return gridOverlay.cellCentre(row: row, col: col)
        }
        mouseController.warp(to: centre)
    }

    /// Reset the first-letter buffer if the user hesitates, so a stale half-
    /// entry can't combine with a much later keypress.
    private func scheduleGridReset() {
        gridResetWork?.cancel()
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self = self, self.gridResetWork === work else { return }
            self.gridFirstChar = nil
            self.gridResetWork = nil
            MainActor.assumeIsolated { self.gridOverlay.highlight(row: nil) }
        }
        gridResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - Saved spots (record a position, warp back with a shortcut)
    //
    // Works in BOTH red mode and the grid layer. `warpModifier + key` (default
    // Cmd+<key>) warps the cursor to a recorded position. To record: press the
    // arm combo (default Cmd+Shift+S), then press `warpModifier + key` for the
    // slot — the live cursor position is stored under that key.

    private var spotArmed: Bool = false
    private var spotArmResetWork: DispatchWorkItem?

    /// CGEventFlags → glyph string (⌃⌥⇧⌘), in the canonical macOS order. Used to
    /// render a saved-spot's warp combo under its grid cell (e.g. "⌘J").
    private static func modifierSymbols(_ flags: CGEventFlags) -> String {
        var s = ""
        if flags.contains(.maskControl)   { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift)     { s += "⇧" }
        if flags.contains(.maskCommand)   { s += "⌘" }
        return s
    }

    /// Arm recording: the next warpModifier+key press stores the current cursor
    /// position into that slot. Auto-activates red mode (so there's a badge to
    /// show the armed state) and auto-disarms after `spotArmWindowMs`.
    private func armSpotRecording() {
        // Ensure red mode is on so the cursor badge is visible to signal "armed".
        if !isActive { toggleActivation() }
        spotArmed = true
        spotArmResetWork?.cancel()
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self = self, self.spotArmResetWork === work else { return }
            print("[mMouse] saved-spot record disarmed (timeout)")
            self.disarmSpotRecording()
        }
        spotArmResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(keys.spotArmWindowMs) / 1000.0, execute: work)
        MainActor.assumeIsolated { badge.setRecording(true) }
        print("[mMouse] saved-spot record ARMED — press the warp combo + a letter/digit to store this spot")
    }

    private func disarmSpotRecording() {
        guard spotArmed || spotArmResetWork != nil else { return }
        spotArmed = false
        spotArmResetWork?.cancel()
        spotArmResetWork = nil
        MainActor.assumeIsolated { badge.setRecording(false) }
    }

    /// Store the live cursor position into the slot for `char`, overwriting any
    /// existing spot on that key, then persist. Disarms recording.
    private func recordSpot(char: Character) {
        let pos = currentCursorPosition()
        let keyName = String(char).lowercased()
        var spots = config.savedSpots.spots.filter { $0.key.lowercased() != keyName }
        spots.append(SavedSpot(key: keyName, x: Double(pos.x), y: Double(pos.y)))
        var newConfig = config
        newConfig.savedSpots.spots = spots
        disarmSpotRecording()
        fireActionIndicators()
        print("[mMouse] saved spot '\(keyName)' → (\(Int(pos.x)),\(Int(pos.y)))")
        // Route through ConfigManager.save → onReload → config didSet (rebuilds
        // spotsByKeyCode). Reuses the normal config-change pipeline.
        MainActor.assumeIsolated { self.persistConfig?(newConfig) }
    }

    /// Warp the cursor to a recorded spot.
    private func warpToSpot(_ point: CGPoint) {
        mouseController.warp(to: point)
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

        // --- Grid-layer trigger (always armed, like activation). Turns the grid
        // layer on (and red mode if it wasn't already) in one action. ---
        if type == .keyDown && !isRepeat && keys.gridKeyCode != EventTapManager.unmappedKey {
            let actualMods = flags.intersection(relevantModifierMask)
            if actualMods == keys.gridModifier && keyCode == keys.gridKeyCode {
                openLayer()
                return nil
            }
        }

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
            // Extra activation combos — single press toggles red mode.
            if !isRepeat && !keys.extraActivations.isEmpty {
                let mods = flags.intersection(relevantModifierMask)
                if keys.extraActivations.contains(where: { $0.modifier == mods && $0.keyCode == keyCode }) {
                    print("[mMouse] extra activation combo — show both layers")
                    activateBothLayers()
                    return nil
                }
            }
        }

        // --- Saved-spot RECORD arm/cancel (always armed, like activation).
        // Auto-activates red mode so the amber badge signals the armed state —
        // so the combo "does something" even when mMouse wasn't active yet. ---
        if type == .keyDown && !isRepeat
            && keys.spotRecordKeyCode != EventTapManager.unmappedKey
            && keyCode == keys.spotRecordKeyCode
            && flags.intersection(relevantModifierMask) == keys.spotRecordModifier {
            if spotArmed {
                print("[mMouse] saved-spot record cancelled")
                disarmSpotRecording()
            } else {
                armSpotRecording()
            }
            return nil
        }

        guard isActive else {
            return Unmanaged.passUnretained(event)
        }

        // --- ACTIVE MODE ---

        // Esc is the ONE full exit: it tears down BOTH layers at once (grid +
        // red mode) regardless of how many are on. toggleActivation() hides the
        // grid layer as part of deactivating. To drop just the grid and stay in
        // red mode, use Enter (peels the grid only — see the Enter handler).
        if keyCode == escapeKeyCode {
            if type == .keyDown && !isRepeat {
                if spotArmed {
                    // While arming a saved-spot record, Esc cancels just that —
                    // it does NOT tear down the layers.
                    print("[mMouse] Esc — cancel saved-spot record")
                    disarmSpotRecording()
                } else {
                    print("[mMouse] Esc — deactivating (exit all layers)")
                    toggleActivation()
                }
            }
            return nil
        }

        // --- Saved spots: warpModifier+key (default Cmd+<key>) either records
        // the live position (when armed) or warps to a recorded position. Works
        // in both red and grid mode. Movement keys are excluded so Cmd+arrow
        // stays scroll; Cmd+<key> is only consumed when armed or a spot exists,
        // so Cmd+C / Cmd+V etc. still pass through to the foreground app. ---
        if type == .keyDown && !isRepeat
            && !keys.spotWarpModifier.isEmpty
            && flags.intersection(relevantModifierMask) == keys.spotWarpModifier
            && !movementKeyCodes.contains(keyCode)
            && keyCode != enterKeyCode && keyCode != keypadEnterKeyCode,
           let ch = EventTapManager.gridKeyChars[keyCode] {
            if spotArmed {
                recordSpot(char: ch)
                return nil
            }
            if let point = spotsByKeyCode[keyCode] {
                warpToSpot(point)
                return nil
            }
        }

        if movementKeyCodes.contains(keyCode) {
            // LAYER MODE: a bare arrow steps the hover cell one cell over and
            // warps the cursor to its centre (discrete cell jumps). Cmd+arrow
            // (scroll) and Shift+arrow (drag) keep their normal meaning.
            if gridShown && !flags.contains(.maskCommand) && !flags.contains(.maskShift) {
                if type == .keyDown, let dir = directionForMovementKey(keyCode) {
                    gridArrowStep(dir)
                }
                return nil   // consume keyUp too — no continuous-move timer here
            }
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
                } else if gridShown {
                    // Layer mode: Enter peels the grid layer off (stays in red
                    // mode), no click — same as the first Esc peel.
                    print("[mMouse] Enter — closing grid layer")
                    hideGrid()
                } else if flags.contains(.maskShift) {
                    handleRightClick()
                } else {
                    // Red mode (no layer): Enter left-clicks AND exits red mode
                    // immediately.
                    print("[mMouse] Enter — click + deactivate")
                    mouseController.click(count: 1)
                    fireActionIndicators()
                    toggleActivation()
                }
            }
            return nil
        }

        // The following two blocks apply ONLY when the grid layer is on. In
        // plain red mode none of them fire, so letters/Backspace pass through
        // and you can type normally.
        if gridShown {
            // Backspace clears a pending grid sequence (re-pick). Only claimed
            // while a first key is buffered — otherwise it passes through.
            if keyCode == deleteKeyCode && gridFirstChar != nil {
                if type == .keyDown && !isRepeat {
                    gridFirstChar = nil
                    gridResetWork?.cancel(); gridResetWork = nil
                    MainActor.assumeIsolated { gridOverlay.highlight(row: nil) }
                }
                return nil
            }

            // GRID JUMP: a BARE (or Shift-) key selects a cell — first key picks
            // a row (or starts a custom label), second warps the cursor (Shift on
            // the second also clicks). Letters always engage; digits only when
            // they're part of a custom label (e.g. "11") so plain digit input
            // still passes through. Cmd/Ctrl/Option + key is NOT a grid key — it
            // falls through to passthrough so Cmd+C/V/… keep working.
            let nonShiftMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
            if flags.intersection(nonShiftMods).isEmpty, let ch = EventTapManager.gridKeyChars[keyCode] {
                let engages = ch.isLetter || gridFirstChar != nil || gridCustomFirstChars.contains(ch)
                if engages {
                    if type == .keyDown && !isRepeat {
                        handleGridKey(ch, shiftHeld: flags.contains(.maskShift))
                    }
                    return nil
                }
            }
        }

        // PRIORITY MODEL: mMouse's own keys (arrows, Enter, Esc, activation, the
        // grid combo, and — only while the layer is on — bare letters) are
        // claimed above. Everything else (typing in red mode, digits,
        // punctuation, system shortcuts) passes through to the foreground app.
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
        hideGrid()
    }

    func activateFromMenu() {
        assert(Thread.isMainThread)
        if !isActive { toggleActivation() }
    }
}
