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


struct AppConfig: Codable, Equatable {
    var activationCombo: ActivationComboConfig
    var keys: KeyConfig
    /// Speed level 1..10 (1 = slowest, 10 = fastest)
    var speed: Int
    /// Modifier+multiplier for speed boost while moving (e.g. Option+arrow = 5×).
    var speedBoost: SpeedBoostConfig

    static let `default` = AppConfig(
        activationCombo: .default,
        keys: .default,
        speed: 3,
        speedBoost: .default
    )

    enum CodingKeys: String, CodingKey {
        case activationCombo, keys, speed, speedBoost
    }

    init(activationCombo: ActivationComboConfig, keys: KeyConfig, speed: Int, speedBoost: SpeedBoostConfig) {
        self.activationCombo = activationCombo
        self.keys = keys
        self.speed = speed
        self.speedBoost = speedBoost
    }

    /// Tolerant decoder so configs written before newer fields were added
    /// continue to load with the default values for those fields.
    /// Also silently ignores the legacy `passthrough` field (removed in v2:
    /// mMouse now passes through everything not explicitly claimed).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activationCombo = try c.decode(ActivationComboConfig.self, forKey: .activationCombo)
        keys            = try c.decode(KeyConfig.self,              forKey: .keys)
        speed           = try c.decode(Int.self,                    forKey: .speed)
        speedBoost      = try c.decodeIfPresent(SpeedBoostConfig.self, forKey: .speedBoost) ?? .default
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
