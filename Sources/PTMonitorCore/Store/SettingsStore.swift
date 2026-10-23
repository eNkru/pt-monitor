import Combine
import Foundation

/// `UserDefaults`-backed settings (design §7).
///
/// A single owner for every persisted key, so `UserDefaults.standard` is not
/// touched anywhere else. `servers` is stored as JSON `[ServerConfig]`;
/// passwords are deliberately **not** part of `ServerConfig` and live in the
/// Keychain (`KeychainStore`).
///
/// The `UserDefaults` instance is injected so checks can use an isolated,
/// temporary suite instead of the real preferences (and so the type is
/// trivially testable without touching the user's configuration).
///
/// `pollInterval` and `showSpeedsInMenuBar` are read-only properties with
/// dedicated setters: the setters enforce the 1–60 s clamp and persist in one
/// place, which direct assignment could bypass.
public final class SettingsStore: ObservableObject {

    /// Persisted keys, owned here so nothing else hard-codes strings.
    public enum Key {
        public static let servers = "servers"
        public static let pollInterval = "pollInterval"
        public static let showSpeedsInMenuBar = "showSpeedsInMenuBar"
        public static let torrentListMode = "torrentListMode"
        /// Legacy boolean (`true` meant "active only"); read once as a
        /// migration fallback by `loadTorrentListMode`.
        public static let showActiveTorrentsOnly = "showActiveTorrentsOnly"
        public static let appLanguage = "appLanguage"
        /// The per-app language override; the only key read at launch, so a
        /// change only takes effect after relaunch. `kCFPreferencesAnyApplication`
        /// keeps the write inside the app's own defaults domain even under a
        /// temporary `UserDefaults` suite (as in `--selftest`).
        static let appleLanguages = "AppleLanguages"
    }

    /// Default poll interval in seconds (design §5).
    public static let defaultPollInterval: TimeInterval = 2
    /// Allowed poll interval range: 1–60 s (design §5).
    public static let pollIntervalRange: ClosedRange<TimeInterval> = 1...60

    private let defaults: UserDefaults

    /// Configured servers, in menu order. Passwords are not included.
    @Published public private(set) var servers: [ServerConfig]

    /// Global poll interval in seconds, always within `pollIntervalRange`.
    @Published public private(set) var pollInterval: TimeInterval

    /// Whether the menu bar shows live speed text alongside the icon (R5.3).
    @Published public private(set) var showSpeedsInMenuBar: Bool

    /// Which slice of the torrent library the dropdown lists: all, actually
    /// downloading, actually uploading, or either. Display-only: changing it
    /// never rebuilds the pollers.
    @Published public private(set) var torrentListMode: TorrentListMode

    /// In-app language choice (R9 switcher), applied to `AppleLanguages` in
    /// `setAppLanguage` so the two can never drift apart.
    @Published public private(set) var appLanguage: AppLanguage

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.servers = Self.loadServers(from: defaults)
        self.pollInterval = Self.loadPollInterval(from: defaults)
        self.showSpeedsInMenuBar = Self.loadShowSpeeds(from: defaults)
        self.torrentListMode = Self.loadTorrentListMode(from: defaults)
        self.appLanguage = Self.loadAppLanguage(from: defaults)
    }

    // MARK: - Server list

    /// Replaces the whole list. A no-op when nothing changed, so callers can
    /// call it freely without churning observers.
    public func replaceServers(_ servers: [ServerConfig]) {
        guard servers != self.servers else { return }
        self.servers = servers
        persistServers()
    }

    public func add(_ server: ServerConfig) {
        var updated = servers
        updated.append(server)
        replaceServers(updated)
    }

    /// Replaces the entry with a matching `id`; ignored when it is unknown.
    public func update(_ server: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        var updated = servers
        updated[index] = server
        replaceServers(updated)
    }

    public func delete(id: UUID) {
        let updated = servers.filter { $0.id != id }
        guard updated.count != servers.count else { return }
        replaceServers(updated)
    }

    /// Enables or disables one server (R3 / AC12). Disabled servers are never
    /// contacted by `MonitorStore`.
    public func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }),
              servers[index].isEnabled != isEnabled else { return }
        var updated = servers
        updated[index].isEnabled = isEnabled
        replaceServers(updated)
    }

    public func server(withID id: UUID) -> ServerConfig? {
        servers.first { $0.id == id }
    }

    // MARK: - Preferences

    /// Sets the poll interval, clamped to `pollIntervalRange`.
    public func setPollInterval(_ interval: TimeInterval) {
        let clamped = Self.clamp(interval)
        guard clamped != pollInterval else { return }
        pollInterval = clamped
        defaults.set(clamped, forKey: Key.pollInterval)
    }

    /// Shows or hides the menu bar speed text; the icon is always shown (R5.3).
    public func setShowSpeedsInMenuBar(_ isEnabled: Bool) {
        guard isEnabled != showSpeedsInMenuBar else { return }
        showSpeedsInMenuBar = isEnabled
        defaults.set(isEnabled, forKey: Key.showSpeedsInMenuBar)
    }

    /// Switches the dropdown's torrent filter (all / downloading / uploading /
    /// active). Display-only (R12): the pollers and snapshots are untouched, so
    /// this never needs to rebuild anything.
    public func setTorrentListMode(_ mode: TorrentListMode) {
        guard mode != torrentListMode else { return }
        torrentListMode = mode
        defaults.set(mode.rawValue, forKey: Key.torrentListMode)
    }

    /// Sets the UI language and applies the matching `AppleLanguages`
    /// override in the same call, so the persisted preference and what the
    /// next launch actually reads cannot drift apart. `AppleLanguages` is
    /// read only at process launch, so the new language shows up after a
    /// relaunch (the preferences UI offers "Relaunch Now").
    public func setAppLanguage(_ language: AppLanguage) {
        guard language != appLanguage else { return }
        appLanguage = language
        defaults.set(language.rawValue, forKey: Key.appLanguage)
        if let codes = language.appleLanguages {
            defaults.set(codes, forKey: Key.appleLanguages)
        } else {
            defaults.removeObject(forKey: Key.appleLanguages)
        }
    }

    /// Clamps an interval into `pollIntervalRange`.
    public static func clamp(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, pollIntervalRange.lowerBound), pollIntervalRange.upperBound)
    }

    // MARK: - Persistence

    private func persistServers() {
        do {
            let data = try JSONEncoder().encode(servers)
            defaults.set(data, forKey: Key.servers)
        } catch {
            // Encoding `[ServerConfig]` cannot realistically fail; if it ever
            // does, keep the in-memory value rather than crashing.
        }
    }

    private static func loadServers(from defaults: UserDefaults) -> [ServerConfig] {
        guard let data = defaults.data(forKey: Key.servers) else { return [] }
        do {
            return try JSONDecoder().decode([ServerConfig].self, from: data)
        } catch {
            // Corrupt or older payload: behave as if unconfigured.
            return []
        }
    }

    private static func loadPollInterval(from defaults: UserDefaults) -> TimeInterval {
        guard defaults.object(forKey: Key.pollInterval) != nil else {
            return defaultPollInterval
        }
        return clamp(defaults.double(forKey: Key.pollInterval))
    }

    private static func loadShowSpeeds(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Key.showSpeedsInMenuBar) as? Bool ?? true
    }

    /// The persisted list mode; an unset or unknown value falls back to `.all`.
    ///
    /// The legacy `showActiveTorrentsOnly` boolean is honoured as a migration
    /// source — an existing user who had the filter on keeps an equivalent
    /// view (`.active`) instead of silently getting the full library back.
    private static func loadTorrentListMode(from defaults: UserDefaults) -> TorrentListMode {
        if let raw = defaults.string(forKey: Key.torrentListMode),
           let mode = TorrentListMode(rawValue: raw) {
            return mode
        }
        return defaults.bool(forKey: Key.showActiveTorrentsOnly) ? .active : .all
    }

    /// The persisted in-app language choice; an unset or unknown key means
    /// "Follow System" (`AppleLanguages` is then untouched).
    private static func loadAppLanguage(from defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: Key.appLanguage)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
}
