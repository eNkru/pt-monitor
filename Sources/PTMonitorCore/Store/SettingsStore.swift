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

    /// In-app language choice (R9 switcher), applied to `AppleLanguages` in
    /// `setAppLanguage` so the two can never drift apart.
    @Published public private(set) var appLanguage: AppLanguage

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.servers = Self.loadServers(from: defaults)
        self.pollInterval = Self.loadPollInterval(from: defaults)
        self.showSpeedsInMenuBar = Self.loadShowSpeeds(from: defaults)
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
        guard defaults.object(forKey: Key.showSpeedsInMenuBar) != nil else {
            return true
        }
        return defaults.bool(forKey: Key.showSpeedsInMenuBar)
    }

    /// One-time migration read: `appLanguage` unset but a per-app
    /// `AppleLanguages` override exists (e.g. written via `defaults write`
    /// before the in-app switcher existed) → derive the choice from its first
    /// entry so the picker shows reality instead of "Follow System". This
    /// runs only when the switcher's own key is absent; later manual
    /// `defaults write` calls are not fought over.
    private static func loadAppLanguage(from defaults: UserDefaults) -> AppLanguage {
        if let raw = defaults.string(forKey: Key.appLanguage),
           let stored = AppLanguage(rawValue: raw) {
            return stored
        }
        if let codes = defaults.stringArray(forKey: Key.appleLanguages),
           let first = codes.first,
           let derived = AppLanguage(appleLanguageCode: first) {
            return derived
        }
        return .system
    }
}
