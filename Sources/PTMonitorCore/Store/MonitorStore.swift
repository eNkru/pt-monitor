import Combine
import Foundation

/// Summed transfer rates and counts across enabled, online servers (design §6).
///
/// Disabled servers contribute nothing (AC12); failed servers are counted so
/// the dropdown can show how many are down.
public struct MonitorAggregate: Equatable, Sendable {
    public var downSpeed: Int64 = 0
    public var upSpeed: Int64 = 0
    public var activeTorrents: Int = 0
    /// Number of servers that produced a snapshot on the last poll.
    public var onlineServers: Int = 0
    /// Number of enabled servers currently in a failed state.
    public var failingServers: Int = 0

    public init() {}
}

/// Overall menu bar indicator state (design §6): idle, actively transferring,
/// or every enabled server failing.
public enum MenuBarState: Equatable, Sendable {
    case idle
    case active
    case error
}

/// Observable poller (design §5).
///
/// One `Task` per **enabled** server, each sleeping the global interval between
/// polls, so a slow or hanging server cannot delay the others (R6). Results are
/// written to `statuses`; identical results are not re-published, so the menu
/// bar does not churn.
///
/// Everything mutable lives on the main actor. The per-server tasks are
/// detached and only hop back onto the main actor to publish a status.
@MainActor
public final class MonitorStore: ObservableObject {

    /// Latest state of every configured server, keyed by `ServerConfig.id`.
    /// Disabled servers are present as `.disabled` and are never contacted.
    @Published public private(set) var statuses: [UUID: ServerStatus] = [:]

    private let settings: SettingsStore
    private let clientFactory: @Sendable (ServerConfig) throws -> TorrentClient
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - settings: the shared settings store (single source of configuration).
    ///   - keychain: password source for the default client factory.
    ///   - clientFactory: builds a client for a server. Injectable so checks
    ///     can run without a live server. Defaults to the real clients, reading
    ///     the password from `keychain`.
    ///   - sleep: the poll delay, injectable so checks do not wait.
    public init(
        settings: SettingsStore,
        keychain: KeychainStore = KeychainStore(),
        clientFactory: (@Sendable (ServerConfig) throws -> TorrentClient)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = MonitorStore.defaultSleep
    ) {
        self.settings = settings
        self.clientFactory = clientFactory ?? MonitorStore.makeDefaultClientFactory(keychain: keychain)
        self.sleep = sleep
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    // MARK: - Lifecycle

    /// Starts polling the currently enabled servers. Safe to call repeatedly.
    public func start() async {
        await reconcile()
    }

    /// Cancels every per-server task and waits for each to finish. Called on app
    /// termination; after this the store no longer polls.
    public func stop() async {
        let running = Array(tasks.values)
        tasks.removeAll()
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    /// Re-reads the configuration and rebuilds the per-server tasks to match it.
    ///
    /// Call this after any add/edit/delete/enable-disable change. Every running
    /// task is cancelled and awaited first: an edit may have changed only the
    /// Keychain password, which is invisible in `ServerConfig`, so the client
    /// must be rebuilt to pick up new credentials. Reconcile is user-triggered,
    /// not per-poll, so the cost is negligible.
    public func reconcile() async {
        let running = Array(tasks.values)
        tasks.removeAll()
        for task in running { task.cancel() }
        for task in running { await task.value }

        let configs = settings.servers
        // Mirror the configuration into `statuses`: disabled servers become
        // `.disabled` and are never contacted (AC12); new enabled servers start
        // as `.connecting`; existing statuses are preserved so the menu bar
        // does not flicker on an unrelated edit.
        var next: [UUID: ServerStatus] = [:]
        for config in configs {
            next[config.id] = config.isEnabled ? (statuses[config.id] ?? .connecting) : .disabled
        }
        if next != statuses {
            statuses = next
        }

        for config in configs where config.isEnabled {
            tasks[config.id] = startTask(for: config)
        }
    }

    /// Immediately polls every enabled server once, without disturbing the
    /// periodic loops (the menu's "Refresh Now", ⌘R).
    public func refreshNow() async {
        let enabled = settings.servers.filter { $0.isEnabled }
        let factory = clientFactory
        await withTaskGroup(of: (UUID, ServerStatus?).self) { group in
            for config in enabled {
                group.addTask {
                    let status = await MonitorStore.poll(config: config, clientFactory: factory)
                    return (config.id, status)
                }
            }
            for await (id, status) in group {
                if let status {
                    setStatus(status, for: id)
                }
            }
        }
    }

    /// Debug-only hook: publishes statuses directly instead of polling, so
    /// `--preview-panel` can render the panel from fixture data. Production
    /// never calls it — polling stays the only writer of `statuses` in the app.
    public func setPreviewStatuses(_ statuses: [UUID: ServerStatus]) {
        self.statuses = statuses
    }

    // MARK: - Menu bar helpers

    /// Aggregate down/up speed and active torrent count (design §6, AC10).
    public var aggregate: MonitorAggregate { Self.aggregate(statuses) }

    /// Overall icon state: idle, active, or all-enabled-failing (design §6).
    public var menuBarState: MenuBarState { Self.menuBarState(statuses) }

    // MARK: - Per-server task

    private func startTask(for config: ServerConfig) -> Task<Void, Never> {
        let factory = clientFactory
        let interval = settings.pollInterval
        let sleeper = sleep
        let id = config.id
        return Task.detached(priority: .utility) { [weak self] in
            // The client is created once and reused, so it can keep its auth
            // state (qBittorrent SID / Transmission session id) between polls.
            var client: TorrentClient?
            while !Task.isCancelled {
                var delay = interval

                if client == nil {
                    do {
                        client = try factory(config)
                    } catch {
                        guard let status = MonitorStore.status(from: error) else { break }
                        await self?.setStatus(status, for: id)
                        delay = MonitorStore.retryDelay(after: status, baseInterval: interval)
                    }
                }

                if let client {
                    do {
                        let snapshot = try await client.fetchSnapshot()
                        await self?.setStatus(.online(snapshot), for: id)
                    } catch {
                        guard let status = MonitorStore.status(from: error) else { break }
                        await self?.setStatus(status, for: id)
                        delay = MonitorStore.retryDelay(after: status, baseInterval: interval)
                    }
                }

                do {
                    try await sleeper(delay)
                } catch {
                    break // cancelled
                }
            }
        }
    }

    /// Publishes a status only when it differs from what is already shown.
    private func setStatus(_ status: ServerStatus, for id: UUID) {
        guard !Self.isEquivalent(statuses[id], status) else { return }
        statuses[id] = status
    }

    // MARK: - Pure helpers (checkable without a live server)

    /// Whether `candidate` would change anything the UI shows.
    ///
    /// `TransferSnapshot.fetchedAt` is deliberately ignored: it changes on every
    /// poll, but a poll that changed no displayed value must not churn the menu
    /// bar (design §5).
    nonisolated public static func isEquivalent(_ current: ServerStatus?, _ candidate: ServerStatus) -> Bool {
        guard let current else { return false }
        switch (current, candidate) {
        case (.disabled, .disabled), (.connecting, .connecting):
            return true
        case (.failed(let lhs), .failed(let rhs)):
            return lhs == rhs
        case (.online(let lhs), .online(let rhs)):
            return lhs.downSpeed == rhs.downSpeed
                && lhs.upSpeed == rhs.upSpeed
                && lhs.activeTorrents == rhs.activeTorrents
                && lhs.totalTorrents == rhs.totalTorrents
                && lhs.freeSpace == rhs.freeSpace
                && lhs.connectionState == rhs.connectionState
        default:
            return false
        }
    }

    /// Sums transfer rates and counts over the online servers.
    nonisolated public static func aggregate(_ statuses: [UUID: ServerStatus]) -> MonitorAggregate {
        var result = MonitorAggregate()
        for status in statuses.values {
            switch status {
            case .online(let snapshot):
                result.downSpeed += max(0, snapshot.downSpeed)
                result.upSpeed += max(0, snapshot.upSpeed)
                result.activeTorrents += max(0, snapshot.activeTorrents)
                result.onlineServers += 1
            case .failed:
                result.failingServers += 1
            case .disabled, .connecting:
                break
            }
        }
        return result
    }

    /// The menu bar icon state (design §6): error only when *every* monitored
    /// server is failing; otherwise active while anything is transferring.
    nonisolated public static func menuBarState(_ statuses: [UUID: ServerStatus]) -> MenuBarState {
        let monitored = statuses.values.filter { status in
            if case .disabled = status { return false }
            return true
        }
        guard !monitored.isEmpty else { return .idle }

        let allFailed = monitored.allSatisfy { status in
            if case .failed = status { return true }
            return false
        }
        if allFailed { return .error }

        let active = monitored.contains { status in
            guard let snapshot = status.snapshot else { return false }
            return snapshot.downSpeed > 0 || snapshot.upSpeed > 0 || snapshot.activeTorrents > 0
        }
        return active ? .active : .idle
    }

    /// Minimum poll delay after credentials were rejected.
    ///
    /// qBittorrent bans an IP once `WebUI/MaxAuthenticationFailCount` logins
    /// have failed (default 5) and counts every failed attempt until a login
    /// *succeeds* — the counter is not time-limited (authcontroller.cpp
    /// `increaseFailedAttempts`). A 2 s poll timer therefore turns one typo into
    /// a one-hour ban. Spacing retries this far apart keeps the app far below
    /// any server's threshold; editing the server (which calls `reconcile`) or
    /// the menu's "Refresh Now" retries immediately.
    public nonisolated static let credentialFailureBackoff: TimeInterval = 600

    /// Minimum poll delay after the server refused this client outright.
    ///
    /// qBittorrent's ban lasts `WebUI/BanDuration` (default 3600 s) and
    /// Transmission's lockout also expires on its own, so polling faster than
    /// this gains nothing and only keeps the error alive.
    public nonisolated static let bannedBackoff: TimeInterval = 900

    /// Delay before the next poll after `status`.
    ///
    /// Credential failures and server-side bans back off hard (never shortening
    /// a user-configured longer interval); everything else uses the base
    /// interval, so transient network trouble recovers quickly.
    nonisolated public static func retryDelay(
        after status: ServerStatus,
        baseInterval: TimeInterval
    ) -> TimeInterval {
        switch status.failure {
        case .auth:
            return max(baseInterval, credentialFailureBackoff)
        case .banned:
            return max(baseInterval, bannedBackoff)
        case .unreachable, .protocolViolation, .serverError, .none:
            return baseInterval
        }
    }

    /// Maps a thrown error into a publishable status. `nil` means "do not
    /// publish" — used for cancellation, which is not a server failure.
    nonisolated public static func status(from error: Error) -> ServerStatus? {
        if error is CancellationError { return nil }
        if let failure = error as? ServerFailure { return .failed(failure) }
        return .failed(.unreachable(error.localizedDescription))
    }

    /// One poll of one server: builds a client, fetches a snapshot, and maps any
    /// failure. Disabled servers are never contacted (AC12).
    nonisolated public static func poll(
        config: ServerConfig,
        clientFactory: @Sendable (ServerConfig) throws -> TorrentClient
    ) async -> ServerStatus? {
        guard config.isEnabled else { return .disabled }
        do {
            let client = try clientFactory(config)
            let snapshot = try await client.fetchSnapshot()
            return .online(snapshot)
        } catch {
            return status(from: error)
        }
    }

    /// The production client factory: picks the client by `kind` and reads the
    /// password from the Keychain, keyed by the server's `id` (R4).
    nonisolated public static func makeDefaultClientFactory(
        keychain: KeychainStore
    ) -> @Sendable (ServerConfig) throws -> TorrentClient {
        { config in
            let password = keychain.password(for: config.id)
            switch config.kind {
            case .qbittorrent:
                return try QBittorrentClient(config: config, password: password)
            case .transmission:
                return try TransmissionClient(config: config, password: password)
            }
        }
    }

    /// Default poll delay. Overridable so checks run without waiting.
    public nonisolated static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
