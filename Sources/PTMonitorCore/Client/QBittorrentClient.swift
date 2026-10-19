import Foundation

// MARK: - WebAPI version

/// qBittorrent's WebAPI version, comparable so optional fields can be gated
/// (research/apis.md §1.4).
public struct WebAPIVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// First WebAPI 2.0 release — anything older speaks the pre-2.0 API.
    public static let v2_0_0 = WebAPIVersion(major: 2, minor: 0, patch: 0)
    /// `free_space_on_disk` was added here (qBittorrent 4.1.4).
    public static let v2_1_1 = WebAPIVersion(major: 2, minor: 1, patch: 1)

    public static func < (lhs: WebAPIVersion, rhs: WebAPIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

// MARK: - Parsing (pure, so `--selftest` can call it directly)

public enum QBittorrentParser {
    /// Parses `"2.11.2"` / `"2.0"` into a comparable version.
    public static func webAPIVersion(_ text: String) -> WebAPIVersion? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
            return nil
        }
        let patch = parts.count >= 3 ? Int(parts[2]) ?? 0 : 0
        return WebAPIVersion(major: major, minor: minor, patch: patch)
    }

    public static func connectionState(_ raw: String?) -> ConnectionState {
        switch raw?.lowercased() {
        case "connected": return .connected
        case "firewalled": return .firewalled
        case "disconnected": return .disconnected
        default: return .unknown
        }
    }

    /// Maps a `POST /api/v2/auth/login` response to a failure, or `nil` on
    /// success.
    ///
    /// The verdict moved from the **body** to the **status** in qBittorrent 5.2
    /// (upstream `authcontroller.cpp`):
    ///
    /// | server | success | wrong credentials |
    /// |--------|---------|-------------------|
    /// | ≤ 5.1  | `200 "Ok."` | `200 "Fails."` |
    /// | 5.2+   | `204` (no body) | `401` |
    ///
    /// Both generations are accepted, so a 204 is success and a 401 is an auth
    /// failure. Reading only the 5.1 shape made every login against a 5.2
    /// server fail with "login failed with HTTP 204" even though the `SID`
    /// cookie had been set.
    public static func loginFailure(statusCode: Int, body: String) -> ServerFailure? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch statusCode {
        case 204:
            // qBittorrent 5.2+: success carries no payload at all, only the
            // `Set-Cookie: SID=…` header.
            return nil
        case 200:
            switch trimmed {
            case "Ok.":
                // Not proof of credentials: the localhost/subnet bypass also
                // returns "Ok." for any password, so callers must not rely on
                // this as an auth check.
                return nil
            case "Fails.":
                return .auth("invalid username or password")
            default:
                return .protocolViolation("unexpected login response \"\(trimmed)\"")
            }
        case 401:
            // qBittorrent 5.2+: `throw APIError(Unauthorized)` for rejected
            // credentials, body "Unauthorized".
            return .auth("invalid username or password")
        case 403:
            // `auth/login` is the only endpoint that can be banned: the server
            // checks the ban before it looks at the credentials
            // (`webapplication.cpp` `validateCredentials`, in ≤5.1 the same
            // check lived in `authcontroller.cpp` `loginAction`), so this is
            // the real thing.
            // The ban lasts `WebUI/BanDuration` (default 3600 s) and is per IP.
            return .banned(
                "the WebUI has banned this Mac's IP after too many failed logins — "
                + "wait for the ban to expire (or restart qBittorrent on the server), "
                + "then check the user name and password"
            )
        case 405:
            return .protocolViolation("login endpoint rejected the request method")
        default:
            return .serverError("login failed with HTTP \(statusCode)")
        }
    }

    /// Maps a **non-login** endpoint's HTTP status to a failure, or `nil` for a
    /// success.
    ///
    /// A `403` here is deliberately *not* the login ban — `auth/login` is the
    /// only endpoint that can be banned. qBittorrent answers any private API
    /// call made without a session with `403` (`webapplication.cpp`:
    /// `!session() && !isPublicAPI` → `ForbiddenHTTPError`), so a `403` that
    /// survives a fresh login means the `SID` cookie was not accepted, not that
    /// the IP was banned.
    public static func endpointFailure(statusCode: Int, context: String) -> ServerFailure? {
        switch statusCode {
        case 200:
            return nil
        case 401:
            return .auth("session rejected; credentials may be wrong")
        case 403:
            return .protocolViolation(
                "\(context): the WebUI rejected an authenticated request (HTTP 403) — the session cookie was not accepted"
            )
        case 404:
            return .protocolViolation("\(context): endpoint not found — is this a qBittorrent WebUI?")
        default:
            return .serverError("\(context): HTTP \(statusCode)")
        }
    }

    /// Maps a qBittorrent torrent `state` string onto the normalised
    /// `TorrentState` (design §6.1, research/apis.md §1.3).
    public static func state(_ raw: String?) -> TorrentState {
        switch raw {
        case "downloading", "metaDL", "forcedDL":
            return .downloading
        case "stalledDL":
            return .stalled
        case "queuedDL", "queuedUP":
            return .queued
        case "uploading", "forcedUP", "stalledUP":
            return .seeding
        case "pausedDL", "pausedUP":
            return .paused
        case "checkingDL", "checkingUP", "checkingResumeData":
            return .checking
        case "allocating", "moving", "unknown":
            return .other
        case "error", "missingFiles":
            return .error
        default:
            return .other
        }
    }

    /// Normalises qBittorrent's eta: `8640000` is the API's "infinite" sentinel
    /// and a negative value is unknown (design §6.1).
    public static func etaSeconds(_ value: Any?) -> Int64? {
        guard let seconds = JSON.int64(value) else { return nil }
        if seconds < 0 || seconds == 8_640_000 { return nil }
        return seconds
    }

    /// Maps the `torrents` map of a `sync/maindata` response (keyed by torrent
    /// hash) onto normalised summaries (R12, design §6.1). Pure, so
    /// `--selftest` can call it directly (AC17).
    ///
    /// `trackers` is the response's top-level `trackers` map. Its real wire
    /// shape is **announce URL → [torrent hash]**, not hash → tracker objects
    /// (verified against a live qBittorrent 5.x); it is therefore only a
    /// fallback for a torrent whose own `tracker` field is empty. Everything
    /// arrives in the same `rid=0` full snapshot, so the site label costs no
    /// extra request (R1).
    public static func summaries(
        fromTorrents torrents: [String: Any],
        trackers: [String: Any] = [:]
    ) -> [TorrentSummary] {
        let fallbackTrackers = trackersByHash(trackers)
        var result: [TorrentSummary] = []
        result.reserveCapacity(torrents.count)
        for (hash, value) in torrents {
            guard let entry = value as? [String: Any] else { continue }
            // The per-torrent `tracker` field is the announce URL qBittorrent
            // itself shows for the torrent, i.e. the first announce entry (R3).
            let announce = (entry["tracker"] as? String) ?? fallbackTrackers[hash]
            result.append(TorrentSummary(
                id: hash,
                name: (entry["name"] as? String) ?? hash,
                state: state((entry["state"] as? String)),
                progress: TorrentSummary.clampedProgress((entry["progress"] as? NSNumber)?.doubleValue),
                downSpeed: JSON.int64(entry["dlspeed"]) ?? 0,
                upSpeed: JSON.int64(entry["upspeed"]) ?? 0,
                etaSeconds: etaSeconds(entry["eta"]),
                totalSize: JSON.int64(entry["total_size"]),
                downloaded: JSON.int64(entry["downloaded"]),
                uploaded: JSON.int64(entry["uploaded"]),
                ratio: ratio(entry["ratio"]),
                seeders: count(entry["num_seeds"], fallback: entry["num_complete"]),
                leechers: count(entry["num_leechs"], fallback: entry["num_incomplete"]),
                site: TorrentSummary.site(fromAnnounceURL: announce),
                trackerStatus: trackerStatus(
                    hasError: entry["has_tracker_error"],
                    hasAnnounceURL: !(announce ?? "").isEmpty
                ),
                category: category(entry["category"])
            ))
        }
        return result
    }

    /// Inverts the top-level `trackers` map (announce URL → [hash]) into
    /// hash → announce URL, keeping the first URL seen for a hash. Only used
    /// when a torrent carries no `tracker` field of its own.
    static func trackersByHash(_ trackers: [String: Any]) -> [String: String] {
        var byHash: [String: String] = [:]
        // Sorted so the choice is deterministic when a torrent announces to
        // several trackers; the site label only needs *a* real announce host.
        for url in trackers.keys.sorted() {
            guard let hashes = trackers[url] as? [Any] else { continue }
            for case let hash as String in hashes where byHash[hash] == nil {
                byHash[hash] = url
            }
        }
        return byHash
    }

    /// qBittorrent's `ratio` is `-1` when it has nothing to divide by; that is
    /// not a real ratio, so it maps to `nil` like a missing field (R10).
    static func ratio(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let ratio = number.doubleValue
        return ratio < 0 ? nil : ratio
    }

    /// A peer count, preferring the connected count and falling back to the
    /// swarm total only when the connected count is absent.
    private static func count(_ primary: Any?, fallback: Any?) -> Int? {
        JSON.int64(primary).map(Int.init) ?? JSON.int64(fallback).map(Int.init)
    }

    /// Tracker health from the per-torrent `has_tracker_error` flag — the real
    /// signal in `sync/maindata` (there are no per-tracker status objects
    /// there). A torrent with no announce URL stays `nil`: there is no tracker
    /// to have an opinion about.
    static func trackerStatus(hasError: Any?, hasAnnounceURL: Bool) -> TrackerStatus? {
        guard hasAnnounceURL else { return nil }
        guard let errored = hasError as? Bool else { return nil }
        return errored ? .notWorking : .working
    }

    /// An empty category is "no category", not a category named "".
    static func category(_ value: Any?) -> String? {
        guard let category = value as? String, !category.isEmpty else { return nil }
        return category
    }

    /// Maps a `GET /api/v2/sync/maindata?rid=0` body into a snapshot.
    ///
    /// `free_space_on_disk` is read only when the cached WebAPI version is at
    /// least 2.1.1 (research/apis.md §1.4); otherwise it is `nil`.
    public static func snapshot(
        fromMainData data: Data,
        webAPIVersion: WebAPIVersion?,
        fetchedAt: Date = Date()
    ) throws -> TransferSnapshot {
        let root = try JSON.object(data)
        guard let serverState = root["server_state"] as? [String: Any] else {
            throw ServerFailure.protocolViolation("sync/maindata response is missing server_state")
        }

        let freeSpace: Int64?
        if let version = webAPIVersion, version >= WebAPIVersion.v2_1_1 {
            freeSpace = JSON.int64(serverState["free_space_on_disk"])
        } else {
            freeSpace = nil
        }

        let torrents = root["torrents"] as? [String: Any] ?? [:]
        let summaries = summaries(
            fromTorrents: torrents,
            trackers: root["trackers"] as? [String: Any] ?? [:]
        )
        // Active count is derived from the normalised states (design §6.1): the
        // same state table drives the torrent list, so there is exactly one
        // mapping to keep in sync with research/apis.md §1.3.
        let active = summaries.reduce(into: 0) { count, summary in
            if summary.state == .downloading || summary.state == .seeding || summary.state == .stalled {
                count += 1
            }
        }

        return TransferSnapshot(
            downSpeed: JSON.int64(serverState["dl_info_speed"]) ?? 0,
            upSpeed: JSON.int64(serverState["up_info_speed"]) ?? 0,
            activeTorrents: active,
            totalTorrents: torrents.count,
            freeSpace: freeSpace,
            connectionState: connectionState((serverState["connection_status"] as? String)),
            fetchedAt: fetchedAt,
            torrents: TorrentSummary.sorted(summaries)
        )
    }
}

// MARK: - Client

/// qBittorrent WebUI API v2 client (research/apis.md §1, design §4.1).
public actor QBittorrentClient: TorrentClient {
    private let config: ServerConfig
    private let password: String
    private let transport: HTTPTransport
    private var cachedWebAPIVersion: WebAPIVersion?
    private var loggedIn = false

    public init(config: ServerConfig, password: String?) throws {
        self.config = config
        self.password = password ?? ""
        self.transport = try HTTPTransport(config: config, password: password)
    }

    public func fetchSnapshot() async throws -> TransferSnapshot {
        try await ensureLoggedIn()
        let version = try await webAPIVersion()
        let response = try await authorizedGET(
            path: "/api/v2/sync/maindata",
            queryItems: [URLQueryItem(name: "rid", value: "0")] // full snapshot every poll
        )
        try checkStatus(response, context: "sync/maindata")
        return try QBittorrentParser.snapshot(fromMainData: response.body, webAPIVersion: version)
    }

    public func testConnection() async throws -> String {
        try await ensureLoggedIn()
        let version = try await webAPIVersion()
        let response = try await authorizedGET(path: "/api/v2/app/version")
        try checkStatus(response, context: "app/version")
        let appVersion = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "qBittorrent \(appVersion) (WebAPI \(version))"
    }

    // MARK: Login

    private func ensureLoggedIn() async throws {
        if loggedIn { return }
        try await login()
    }

    private func login() async throws {
        var request = URLRequest(url: transport.url(path: "/api/v2/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formURLEncoded(username: config.username, password: password).utf8)
        // Deliberately no Origin / Referer header: qBittorrent's CSRF check only
        // rejects requests that carry one of them (research/apis.md §1.1).
        let response = try await transport.send(request)
        if let failure = QBittorrentParser.loginFailure(statusCode: response.statusCode, body: response.text) {
            loggedIn = false
            throw failure
        }
        loggedIn = true
    }

    // MARK: Requests

    /// GETs an authenticated endpoint. A single `401` **or `403`** triggers one
    /// re-login and one retry, then the failure propagates — never a login loop.
    ///
    /// Both codes mean "this request carried no usable session": qBittorrent
    /// answers a private API call made without a session with `403`
    /// (`webapplication.cpp`: `!session() && !isPublicAPI` → `ForbiddenHTTPError`),
    /// and a stale or host-header-rejected session with `401`.
    private func authorizedGET(path: String, queryItems: [URLQueryItem] = []) async throws -> HTTPResponse {
        var didRetry = false
        while true {
            var request = URLRequest(url: transport.url(path: path, queryItems: queryItems))
            request.httpMethod = "GET"
            let response = try await transport.send(request)
            if (response.statusCode == 401 || response.statusCode == 403), !didRetry {
                loggedIn = false
                try await login()
                didRetry = true
                continue
            }
            return response
        }
    }

    /// Fetches and caches the WebAPI version once, rejecting pre-2.0 servers.
    private func webAPIVersion() async throws -> WebAPIVersion {
        if let cached = cachedWebAPIVersion { return cached }
        let response = try await authorizedGET(path: "/api/v2/app/webapiVersion")
        try checkStatus(response, context: "app/webapiVersion")
        guard let version = QBittorrentParser.webAPIVersion(response.text) else {
            throw ServerFailure.protocolViolation("could not parse WebAPI version \"\(response.text)\"")
        }
        guard version >= WebAPIVersion.v2_0_0 else {
            throw ServerFailure.protocolViolation(
                "qBittorrent WebAPI 2.0 or newer is required (server reports \(version))"
            )
        }
        cachedWebAPIVersion = version
        return version
    }

    private func checkStatus(_ response: HTTPResponse, context: String) throws {
        if let failure = QBittorrentParser.endpointFailure(statusCode: response.statusCode, context: context) {
            throw failure
        }
    }

    // MARK: Form encoding

    static func formURLEncoded(username: String, password: String) -> String {
        "username=\(percentEncode(username))&password=\(percentEncode(password))"
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
