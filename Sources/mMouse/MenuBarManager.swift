import AppKit
import Foundation

@MainActor
final class MenuBarManager: NSObject {

    private let statusItem: NSStatusItem
    private let eventTap: EventTapManager
    private let config: ConfigManager

    private let activeSymbol = "🟢"
    private let inactiveSymbol = "⚪"

    init(eventTap: EventTapManager, config: ConfigManager) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.eventTap = eventTap
        self.config = config
        super.init()
        setupItem()
        rebuildMenu(active: eventTap.isActive)

        eventTap.onActivationChange = { [weak self] active in
            self?.updateState(active: active)
        }
    }

    /// Public entry point for callers (e.g., AppDelegate on config hot-reload)
    /// to refresh the menu so combo hints/labels stay in sync.
    func refresh() {
        updateState(active: eventTap.isActive)
    }

    private func setupItem() {
        if let button = statusItem.button {
            button.title = "\(inactiveSymbol) mM"
            button.toolTip = "mMouse — keyboard mouse control"
        }
    }

    private func updateState(active: Bool) {
        if let button = statusItem.button {
            button.title = "\(active ? activeSymbol : inactiveSymbol) mM"
        }
        rebuildMenu(active: active)
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
