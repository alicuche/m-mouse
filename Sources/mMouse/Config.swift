import Foundation

struct ActivationComboConfig: Codable, Equatable {
    /// Modifier key required for the activation sequence (e.g., "command", "control", "option", "shift", "none")
    var modifier: String
    /// The key that must be pressed `repeatCount` times in quick succession
    var key: String
    /// Number of times the key must be pressed (e.g., 2 for double-tap)
    var repeatCount: Int
    /// Max milliseconds between presses for the sequence to count
    var windowMs: Int

    static let `default` = ActivationComboConfig(
        modifier: "command",
        key: ";",
        repeatCount: 1,
        windowMs: 500
    )
}

struct KeyConfig: Codable, Equatable {
    var up: String
    var down: String
    var left: String
    var right: String

    static let `default` = KeyConfig(
        up: "up",
        down: "down",
        left: "left",
        right: "right"
    )
}

struct SpeedBoostConfig: Codable, Equatable {
    /// Modifier that, when held with a movement key, multiplies movement speed.
    /// Same syntax as activation modifier — supports combos like "command+shift".
    var modifier: String
    /// Speed multiplier when boost modifier is held (default 5×).
    var multiplier: Double

    // Default is Option because Cmd is now hardcoded for scroll
    // (Cmd + arrow). Users can still override to whatever modifier they want;
    // setting "command" will silently lose to the scroll branch in active mode.
    static let `default` = SpeedBoostConfig(modifier: "option", multiplier: 5)
}


struct GridComboConfig: Codable, Equatable {
    /// Modifier for the grid-layer trigger (same syntax as activation modifier).
    var modifier: String
    /// Key that, with `modifier`, turns the grid layer on (also activates red
    /// mode if it wasn't already).
    var key: String

    // Default Cmd+' — sibling of the Cmd+; activation combo (adjacent key).
    static let `default` = GridComboConfig(modifier: "command", key: "'")
}

/// A pinned, fixed label for one grid cell. Replaces the default row+col code
/// at `cell` with `label` — shown on a fluorescent-green pill and typed to warp there.
struct GridCustomLabel: Codable, Equatable {
    /// The cell to relabel, identified by its DEFAULT two-letter code
    /// (row letter + column letter, e.g. "FA" = row F, col A).
    var cell: String
    /// The custom label shown and typed instead (e.g. "S1", "11"). 1–2 chars
    /// of letters/digits work best; typing it in the layer warps to the cell.
    var label: String
}

struct GridConfig: Codable, Equatable {
    /// Combo that turns the grid layer on (on top of red mode).
    var combo: GridComboConfig
    /// Target cell WIDTH in points. cols = round(displayWidth / targetCellPx).
    var targetCellPx: Int
    /// Optional target cell HEIGHT in points. When nil, cells are square (uses
    /// targetCellPx for height too). Set it smaller than the width to get
    /// wide rectangular cells (more rows). rows = round(displayHeight / this).
    var targetCellHeightPx: Int? = nil
    /// Fixed custom labels for specific cells — easier-to-remember shortcuts
    /// that override the default row+col code (rendered green). Typing a label
    /// warps the cursor to its cell. Set to `[]` to disable all of them.
    var customLabels: [GridCustomLabel] = GridConfig.defaultCustomLabels

    /// Built-in pinned labels. Kept here (not just in the on-disk config) so
    /// they survive a config reset and apply to configs written before the
    /// field existed.
    static let defaultCustomLabels: [GridCustomLabel] = [
        GridCustomLabel(cell: "FA", label: "S1"),
        GridCustomLabel(cell: "HA", label: "S2"),
        GridCustomLabel(cell: "JC", label: "11"),
        GridCustomLabel(cell: "LK", label: "22"),
        GridCustomLabel(cell: "WI", label: "33"),
    ]

    static let `default` = GridConfig(combo: .default, targetCellPx: 150)

    enum CodingKeys: String, CodingKey {
        case combo, targetCellPx, targetCellHeightPx, customLabels
    }

    init(combo: GridComboConfig, targetCellPx: Int, targetCellHeightPx: Int? = nil,
         customLabels: [GridCustomLabel] = GridConfig.defaultCustomLabels) {
        self.combo = combo
        self.targetCellPx = targetCellPx
        self.targetCellHeightPx = targetCellHeightPx
        self.customLabels = customLabels
    }

    /// Tolerant decode: older configs lacking `customLabels`/`targetCellHeightPx`
    /// keep loading and pick up the built-in pinned labels.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        combo = try c.decode(GridComboConfig.self, forKey: .combo)
        targetCellPx = try c.decode(Int.self, forKey: .targetCellPx)
        targetCellHeightPx = try c.decodeIfPresent(Int.self, forKey: .targetCellHeightPx)
        customLabels = try c.decodeIfPresent([GridCustomLabel].self, forKey: .customLabels)
            ?? GridConfig.defaultCustomLabels
    }
}

/// One recorded warp target: pressing `warpModifier + key` while active jumps
/// the cursor to (x, y) — absolute CG coordinates (top-left origin) captured on
/// the main display. Added/overwritten by the in-app recorder.
struct SavedSpot: Codable, Equatable {
    /// Single letter/digit that, with the warp modifier, warps here (e.g. "j", "1").
    var key: String
    var x: Double
    var y: Double
}

/// "Saved spots" — record cursor positions and warp back to them with
/// `warpModifier + key` (works in red mode AND the grid layer). Recording is
/// ARMED with `recordModifier + recordKey`; the next `warpModifier + key` press
/// then stores the live cursor position into that slot.
struct SavedSpotsConfig: Codable, Equatable {
    /// Modifier held with a spot key to warp there (default "command" → Cmd+key).
    var warpModifier: String
    /// Modifier for the arm-record combo (default "command+shift").
    var recordModifier: String
    /// Key for the arm-record combo (default "s" → Cmd+Shift+S arms recording).
    var recordKey: String
    /// How long (ms) recording stays armed waiting for the slot key.
    var armWindowMs: Int
    /// Recorded targets (added/overwritten by the in-app recorder).
    var spots: [SavedSpot]

    static let `default` = SavedSpotsConfig(
        warpModifier: "command",
        recordModifier: "command+shift",
        recordKey: "s",
        armWindowMs: 8000,
        spots: []
    )

    enum CodingKeys: String, CodingKey {
        case warpModifier, recordModifier, recordKey, armWindowMs, spots
    }

    init(warpModifier: String, recordModifier: String, recordKey: String, armWindowMs: Int, spots: [SavedSpot]) {
        self.warpModifier = warpModifier
        self.recordModifier = recordModifier
        self.recordKey = recordKey
        self.armWindowMs = armWindowMs
        self.spots = spots
    }

    /// Tolerant decode so older configs lacking any of these fields keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warpModifier   = try c.decodeIfPresent(String.self, forKey: .warpModifier) ?? "command"
        recordModifier = try c.decodeIfPresent(String.self, forKey: .recordModifier) ?? "command+shift"
        recordKey      = try c.decodeIfPresent(String.self, forKey: .recordKey) ?? "s"
        armWindowMs    = try c.decodeIfPresent(Int.self, forKey: .armWindowMs) ?? 8000
        spots          = try c.decodeIfPresent([SavedSpot].self, forKey: .spots) ?? []
    }
}

struct AppConfig: Codable, Equatable {
    var activationCombo: ActivationComboConfig
    /// Extra activation combos — each toggles red mode on a single press (their
    /// `repeatCount`/`windowMs` are ignored). Lets several shortcuts (e.g. both
    /// Cmd+E and Cmd+Q) enter red mode.
    var additionalActivationCombos: [ActivationComboConfig]
    var keys: KeyConfig
    /// Speed level 1..10 (1 = slowest, 10 = fastest)
    var speed: Int
    /// Modifier+multiplier for speed boost while moving (e.g. Option+arrow = 5×).
    var speedBoost: SpeedBoostConfig
    /// Grid-jump overlay (Cmd+' → labelled matrix → 2 keys warp the cursor).
    var grid: GridConfig
    /// Saved spots — record cursor positions and warp back with Cmd+<key>.
    var savedSpots: SavedSpotsConfig

    static let `default` = AppConfig(
        activationCombo: .default,
        additionalActivationCombos: [],
        keys: .default,
        speed: 3,
        speedBoost: .default,
        grid: .default,
        savedSpots: .default
    )

    enum CodingKeys: String, CodingKey {
        case activationCombo, additionalActivationCombos, keys, speed, speedBoost, grid, savedSpots
    }

    init(activationCombo: ActivationComboConfig, additionalActivationCombos: [ActivationComboConfig], keys: KeyConfig, speed: Int, speedBoost: SpeedBoostConfig, grid: GridConfig, savedSpots: SavedSpotsConfig) {
        self.activationCombo = activationCombo
        self.additionalActivationCombos = additionalActivationCombos
        self.keys = keys
        self.speed = speed
        self.speedBoost = speedBoost
        self.grid = grid
        self.savedSpots = savedSpots
    }

    /// Tolerant decoder so configs written before newer fields were added
    /// continue to load with the default values for those fields.
    /// Also silently ignores the legacy `passthrough` field (removed in v2:
    /// mMouse now passes through everything not explicitly claimed).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activationCombo = try c.decode(ActivationComboConfig.self, forKey: .activationCombo)
        additionalActivationCombos = try c.decodeIfPresent([ActivationComboConfig].self, forKey: .additionalActivationCombos) ?? []
        keys            = try c.decode(KeyConfig.self,              forKey: .keys)
        speed           = try c.decode(Int.self,                    forKey: .speed)
        speedBoost      = try c.decodeIfPresent(SpeedBoostConfig.self, forKey: .speedBoost) ?? .default
        grid            = try c.decodeIfPresent(GridConfig.self,       forKey: .grid)       ?? .default
        savedSpots      = try c.decodeIfPresent(SavedSpotsConfig.self, forKey: .savedSpots) ?? .default
    }
}

final class ConfigManager: @unchecked Sendable {
    static let shared = ConfigManager()

    let configURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mMouse.json")
    }()

    private(set) var config: AppConfig = .default
    private var fileWatcher: DispatchSourceFileSystemObject?
    /// Always delivered on the main thread (file watcher uses `queue: .main`
    /// and `reloadAndNotify()` is called from main contexts).
    var onReload: (@MainActor (AppConfig) -> Void)?

    private init() {
        createDefaultIfMissing()
        loadConfig()
        watchFile()
    }

    private func createDefaultIfMissing() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        saveDefault()
    }

    func saveDefault() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(AppConfig.default) else { return }
        try? data.write(to: configURL)
        print("[mMouse] Created default config at \(configURL.path)")
    }

    /// Persist a programmatic config change (e.g. a recorded saved-spot) to disk
    /// and push it to observers immediately. Setting `config` to `newConfig`
    /// FIRST means the file-watcher reload that our own write triggers compares
    /// equal and won't double-fire `onReload`.
    @MainActor
    func save(_ newConfig: AppConfig) {
        config = newConfig
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(newConfig) {
            try? data.write(to: configURL)
            print("[mMouse] Config saved to \(configURL.path)")
        }
        onReload?(newConfig)
    }

    /// Reload from disk and notify observers if the config changed.
    /// Single entry point shared by the file watcher and manual reload.
    @MainActor
    func reloadAndNotify() {
        let old = config
        loadConfig()
        if config != old {
            onReload?(config)
        }
    }

    /// Internal — invariant: callers must be on main (`init`, `reloadAndNotify`).
    /// Kept `private` so external code can't accidentally invoke from a background thread.
    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL) else {
            config = .default
            return
        }
        let decoder = JSONDecoder()
        do {
            var loaded = try decoder.decode(AppConfig.self, from: data)
            loaded.speed = max(1, min(10, loaded.speed))
            loaded.activationCombo.repeatCount = max(1, min(10, loaded.activationCombo.repeatCount))
            loaded.activationCombo.windowMs    = max(50, min(5000, loaded.activationCombo.windowMs))
            loaded.grid.targetCellPx           = max(60, min(400, loaded.grid.targetCellPx))
            if let h = loaded.grid.targetCellHeightPx {
                loaded.grid.targetCellHeightPx = max(30, min(400, h))
            }
            config = loaded
            print("[mMouse] Config loaded from \(configURL.path)")
        } catch {
            print("[mMouse] Config parse error: \(error). Using defaults.")
            config = .default
        }
    }

    /// Watches the config file directly (not the parent directory) to avoid
    /// thrashing on every unrelated file event in the home directory.
    /// On atomic-save (rename/delete), re-establishes the watcher on the new inode.
    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil

        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            // File missing — try to recreate, then retry once.
            createDefaultIfMissing()
            let retryFd = open(configURL.path, O_EVTONLY)
            guard retryFd >= 0 else {
                print("[mMouse] Could not open config for watching: \(configURL.path)")
                return
            }
            installSource(fd: retryFd)
            return
        }
        installSource(fd: fd)
    }

    private func installSource(fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let source = source else { return }
            let mask = source.data
            let needsRewatch = !mask.intersection([.delete, .rename, .revoke]).isEmpty

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.reloadAndNotify()
                    if needsRewatch {
                        self.watchFile()
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }
}
