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
    /// Torrent states counted as "active" (research/apis.md §1.3).
    public static let activeStates: Set<String> = [
        "downloading", "metaDL", "forcedDL",
        "uploading", "forcedUP", "stalledDL", "stalledUP"
    ]

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
    /// success. Wrong credentials return **HTTP 200 with body `Fails.`** — not
    /// a 401 — so the body must be checked (research/apis.md §1.1).
    public static func loginFailure(statusCode: Int, body: String) -> ServerFailure? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch statusCode {
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
            return .auth("invalid username or password")
        case 403:
            return .serverError("the server banned this IP address after repeated failed logins")
        case 405:
            return .protocolViolation("login endpoint rejected the request method")
        default:
            return .serverError("login failed with HTTP \(statusCode)")
        }
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
        let active = torrents.values.reduce(into: 0) { count, value in
            guard let entry = value as? [String: Any],
                  let state = entry["state"] as? String,
                  activeStates.contains(state) else { return }
            count += 1
        }

        return TransferSnapshot(
            downSpeed: JSON.int64(serverState["dl_info_speed"]) ?? 0,
            upSpeed: JSON.int64(serverState["up_info_speed"]) ?? 0,
            activeTorrents: active,
            totalTorrents: torrents.count,
            freeSpace: freeSpace,
            connectionState: connectionState(JSON.string(serverState["connection_status"])),
            fetchedAt: fetchedAt
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

    /// GETs an authenticated endpoint. A single `401` triggers one re-login and
    /// one retry, then the failure propagates — never a login loop.
    private func authorizedGET(path: String, queryItems: [URLQueryItem] = []) async throws -> HTTPResponse {
        var didRetry = false
        while true {
            var request = URLRequest(url: transport.url(path: path, queryItems: queryItems))
            request.httpMethod = "GET"
            let response = try await transport.send(request)
            if response.statusCode == 401, !didRetry {
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
        switch response.statusCode {
        case 200:
            return
        case 401:
            throw ServerFailure.auth("session rejected; credentials may be wrong")
        case 403:
            throw ServerFailure.serverError("the server banned this IP address (too many failed logins or an IP/subnet restriction)")
        case 404:
            throw ServerFailure.protocolViolation("\(context): endpoint not found — is this a qBittorrent WebUI?")
        default:
            throw ServerFailure.serverError("\(context): HTTP \(response.statusCode)")
        }
    }

    // MARK: Form encoding

    static func formURLEncoded(username: String, password: String) -> String {
        "username=\(percentEncode(username))&password=\(percentEncode(password))"
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
