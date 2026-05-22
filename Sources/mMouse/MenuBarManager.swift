import AppKit
import Foundation

@MainActor
final class MenuBarManager: NSObject {

    private let statusItem: NSStatusItem
    private let eventTap: EventTapManager
    private let config: ConfigManager

    /// Pre-loaded template image used for the menu bar icon (the mM monogram).
    /// `isTemplate = true` makes macOS auto-tint it to match the menu bar
    /// (black in light mode, white in dark mode, with proper highlight handling).
    private let menuIconImage: NSImage? = {
        // NSImage(named:) walks the bundle and picks the right @2x variant
        // for retina displays automatically when "MenuIcon.png" +
        // "MenuIcon@2x.png" are both present in Contents/Resources.
        let img = NSImage(named: "MenuIcon")
        img?.isTemplate = true
        return img
    }()

    init(eventTap: EventTapManager, config: ConfigManager) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.eventTap = eventTap
        self.config = config
        super.init()
        setupItem()
        rebuildMenu(active: eventTap.isActive)

        eventTap.onActivationChange = { [weak self] active in
            self?.updateState(active: active)
        }
        eventTap.onActionFire = { [weak self] in
            self?.flashAction()
        }
    }

    /// Public entry point for callers (e.g., AppDelegate on config hot-reload)
    /// to refresh the menu so combo hints/labels stay in sync.
    func refresh() {
        updateState(active: eventTap.isActive)
    }

    private func setupItem() {
        if let button = statusItem.button {
            if let icon = menuIconImage {
                button.image = icon
                button.title = ""
            } else {
                // Fallback if the bundle didn't ship MenuIcon.png (e.g. dev
                // run from .build without `make bundle`).
                button.title = "mM"
            }
            button.toolTip = "mMouse — keyboard mouse control"
            // Active mode is indicated by the small CursorBadge following the
            // cursor on screen; here we tint the menu icon green when active
            // so users see the state at a glance in the menu bar too.
            applyActiveTint(active: eventTap.isActive, button: button)
        }
    }

    private func updateState(active: Bool) {
        if let button = statusItem.button {
            applyActiveTint(active: active, button: button)
        }
        rebuildMenu(active: active)
    }

    /// Tint the template image red while active, default color otherwise.
    /// Matches the cursor badge color so both UI cues read "active mode" the
    /// same way. AppKit handles a template image's color via `contentTintColor`
    /// on the hosting view (the status item button itself).
    private func applyActiveTint(active: Bool, button: NSStatusBarButton) {
        button.contentTintColor = active ? .systemRed : nil
    }

    /// Bumped per flash so a delayed restore from an OLD flash can't clobber
    /// the result of a NEW flash that fired in the meantime.
    private var flashGen: UInt64 = 0

    /// Flash the menu bar icon green for ~150ms — mirrors the cursor badge's
    /// action-confirmation flash so the two indicators stay in sync visually.
    func flashAction() {
        guard let button = statusItem.button else { return }
        flashGen &+= 1
        let gen = flashGen
        button.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.flashGen == gen, let button = self.statusItem.button else { return }
            // Restore the resting color appropriate for current active state.
            self.applyActiveTint(active: self.eventTap.isActive, button: button)
        }
    }

    private func rebuildMenu(active: Bool) {
        let menu = NSMenu()

        let stateItem = NSMenuItem(title: active ? "Status: ACTIVE" : "Status: inactive",
                                   action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        let combo = config.config.activationCombo
        let hint = "Toggle: \(combo.modifier.capitalized)+\(combo.key.uppercased()) × \(combo.repeatCount)"
        let hintItem = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        if active {
            let clickHint = NSMenuItem(title: "Click: Enter  •  DblClick: Enter×2  •  RClick: Shift+Enter",
                                       action: nil, keyEquivalent: "")
            clickHint.isEnabled = false
            menu.addItem(clickHint)
            let lockHint = NSMenuItem(title: "🔒 Other keys blocked while active",
                                      action: nil, keyEquivalent: "")
            lockHint.isEnabled = false
            menu.addItem(lockHint)
        }

        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: active ? "Deactivate" : "Activate",
                                action: #selector(toggleAction),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let pathItem = NSMenuItem(title: "Config: \(config.configURL.path)", action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)

        // Status-bar pull-down items don't register global hotkeys — only
        // act as fire-when-clicked. Leave keyEquivalent empty to avoid
        // misleading users into expecting Cmd+O / Cmd+Q to work standalone.
        let openItem = NSMenuItem(title: "Open Config", action: #selector(openConfigAction), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigAction), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealConfigAction), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit mMouse", action: #selector(quitAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleAction() {
        if eventTap.isActive {
            eventTap.forceDeactivate()
        } else {
            eventTap.activateFromMenu()
        }
    }

    @objc private func openConfigAction() {
        let url = config.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            config.saveDefault()
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealConfigAction() {
        NSWorkspace.shared.activateFileViewerSelecting([config.configURL])
    }

    @objc private func reloadConfigAction() {
        // Route through the same notification path as the file watcher so
        // every subscriber (eventTap, menu refresh, future ones) updates.
        config.reloadAndNotify()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
