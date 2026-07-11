import AppKit
import ApplicationServices
import Foundation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mouseController: MouseController!
    private var eventTap: EventTapManager!
    private var menuBar: MenuBarManager!
    private var badge: CursorBadge!
    private var gridOverlay: GridOverlay!
    private let configManager = ConfigManager.shared

    private var permissionPollTimer: Timer?

    static func main() {
        // Unbuffer stdout so `[mMouse]` logs appear immediately when redirected.
        setbuf(stdout, nil)

        // Singleton: kill any other instance to avoid duplicate event taps
        // (two taps intercepting the same keys → activation count splits
        // between them → state machine never reaches threshold to toggle).
        killOtherInstances()

        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func killOtherInstances() {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.alicuche.mMouse"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
            .filter { $0.processIdentifier != myPid }
        guard !others.isEmpty else { return }
        print("[mMouse] Found \(others.count) other mMouse instance(s) — terminating to enforce singleton")
        for app in others {
            app.terminate()
        }
        // Brief wait so their event tap is released before we install ours.
        Thread.sleep(forTimeInterval: 0.3)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        mouseController = MouseController()
        badge = CursorBadge()
        gridOverlay = GridOverlay()
        // EventTapManager.init → rebuildKeyTables() sets speedLevel from config;
        // no need to set it here.

        eventTap = EventTapManager(config: configManager.config, mouseController: mouseController, badge: badge, gridOverlay: gridOverlay)
        menuBar = MenuBarManager(eventTap: eventTap, config: configManager)

        configManager.onReload = { [weak self] cfg in
            guard let self = self else { return }
            self.eventTap.config = cfg
            self.menuBar.refresh()
            print("[mMouse] Config hot-reloaded")
        }

        // Let the event tap persist programmatic changes (recorded saved-spots)
        // through the same save → onReload pipeline as a manual config edit.
        eventTap.persistConfig = { [weak self] cfg in
            self?.configManager.save(cfg)
        }

        ensureAccessibilityAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Force-deactivate ends any in-progress drag (posts mouseUp so the
        // foreground app doesn't get stuck with a hanging button-down) and
        // releases held movement/scroll timers.
        eventTap?.forceDeactivate()
    }

    private func ensureAccessibilityAndStart() {
        if AXIsProcessTrusted() {
            let ok = eventTap.start()
            if !ok {
                offerRelaunch(reason: .tccStale)
            }
            return
        }

        showAccessibilityAlert()

        // Poll for grant. macOS often requires the process to restart for
        // a new TCC grant to take effect — once detected, relaunch.
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if AXIsProcessTrusted() {
                    self.permissionPollTimer?.invalidate()
                    self.permissionPollTimer = nil
                    self.relaunchApp()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private enum RelaunchReason {
        case tccStale
    }

    private func offerRelaunch(reason: RelaunchReason) {
        let alert = NSAlert()
        alert.messageText = "mMouse needs to relaunch"
        switch reason {
        case .tccStale:
            alert.informativeText = """
            Accessibility appears granted, but the keyboard listener couldn't start.

            This usually means macOS hasn't applied the permission yet.
            Click Relaunch — mMouse will quit and reopen automatically.
            """
        }
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApp()
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Spawns a new instance via /usr/bin/open then terminates self.
    /// Only terminates if the spawn succeeded — otherwise the user would lose
    /// the running app with no replacement (esp. on dev runs where the binary
    /// isn't a proper .app bundle).
    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
        } catch {
            print("[mMouse] Failed to relaunch: \(error)")
            showRelaunchFailedAlert(error: error)
            return
        }
        // 200ms empirically gives /usr/bin/open time to detach into its own
        // process group before our PID exits. Lower values caused the spawned
        // launch to be aborted on some macOS versions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    private func showRelaunchFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "mMouse couldn't relaunch itself"
        alert.informativeText = "\(error.localizedDescription)\n\nPlease quit and reopen mMouse manually for the new Accessibility permission to take effect."
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func showAccessibilityAlert() {
        // Accessory apps (LSUIElement) don't bring themselves to front by
        // default — the modal would render behind whatever app is active.
        // Force activation so the user actually sees the prompt.
        NSApp.activate(ignoringOtherApps: true)
        print("[mMouse] Accessibility NOT granted — showing alert")
        let alert = NSAlert()
        alert.messageText = "mMouse needs Accessibility access"
        alert.informativeText = """
        Grant Accessibility permission to mMouse in:
        System Settings → Privacy & Security → Accessibility

        After granting, mMouse will automatically relaunch itself to apply the permission.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            promptAccessibilityAndOpenSettings()
        }
    }

    /// Wrapped to confine the (Swift-6-strict-unsafe) global `kAXTrustedCheckOptionPrompt`
    /// access into a single nonisolated boundary.
    nonisolated private func promptAccessibilityAndOpenSettings() {
        let key = "AXTrustedCheckOptionPrompt"
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.async {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
