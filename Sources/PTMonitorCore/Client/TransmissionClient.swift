import Foundation

// MARK: - Parsing (pure, so `--selftest` can call it directly)

public enum TransmissionParser {
    /// `torrent-get` requires an explicit `fields` array in the old protocol
    /// (research/apis.md §2.2). The list feeds the dropdown only.
    public static let torrentFields: [String] = [
        "id", "name", "status", "percentDone", "rateDownload", "rateUpload",
        "eta", "error", "errorString"
    ]

    /// Parses a full `session-stats` RPC response body.
    ///
    /// HTTP 200 is returned even on failure, so the `result` string — not the
    /// status code — determines success (research/apis.md §2.1.2).
    public static func snapshot(fromResponseBody data: Data, fetchedAt: Date = Date()) throws -> TransferSnapshot {
        let root = try JSON.object(data)
        if let result = root["result"] as? String, result != "success" {
            throw ServerFailure.serverError(result)
        }
        guard let arguments = root["arguments"] as? [String: Any] else {
            throw ServerFailure.protocolViolation("session-stats response is missing arguments")
        }
        return snapshot(fromSessionStats: arguments, fetchedAt: fetchedAt)
    }

    /// Normalises the `session-stats` arguments dictionary. Speeds are B/s.
    public static func snapshot(fromSessionStats arguments: [String: Any], fetchedAt: Date = Date()) -> TransferSnapshot {
        TransferSnapshot(
            downSpeed: JSON.int64(arguments["downloadSpeed"]) ?? 0,
            upSpeed: JSON.int64(arguments["uploadSpeed"]) ?? 0,
            activeTorrents: JSON.int(arguments["activeTorrentCount"]) ?? 0,
            totalTorrents: JSON.int(arguments["torrentCount"]) ?? 0,
            freeSpace: nil,
            connectionState: .connected,
            fetchedAt: fetchedAt
        )
    }

    /// `free-space` returns `size-bytes` on Transmission 2.80+ (rpc 15+).
    public static func freeSpace(fromArguments arguments: [String: Any]) -> Int64? {
        JSON.int64(arguments["size-bytes"])
    }
}

// MARK: - Client

/// Transmission RPC client (research/apis.md §2, design §4.2).
///
/// Uses the old camelCase protocol only — accepted by every Transmission in
/// the field, including 4.1+ (which deprecates but still accepts it).
public actor TransmissionClient: TorrentClient {
    /// `free-space` does a synchronous `statvfs` that can block on a hung
    /// NFS/SMB mount, so it runs on a slow cadence of its own and never stalls
    /// the speed poll (design §4.2).
    static let freeSpaceRefreshInterval: TimeInterval = 30

    private let config: ServerConfig
    private let password: String
    private let transport: HTTPTransport
    private var sessionId: String?
    private var downloadDirectory: String?
    private var cachedFreeSpace: Int64?
    private var lastFreeSpaceFetch: Date?

    public init(config: ServerConfig, password: String?) throws {
        self.config = config
        self.password = password ?? ""
        self.transport = try HTTPTransport(config: config, password: password)
    }

    public func fetchSnapshot() async throws -> TransferSnapshot {
        let stats = try await rpc("session-stats")
        var snapshot = TransmissionParser.snapshot(fromSessionStats: stats)

        // Required by the old protocol; the per-torrent list is consumed by the
        // dropdown in a later step (implement.md step 11).
        _ = try await rpc("torrent-get", arguments: ["fields": TransmissionParser.torrentFields])

        if let freeSpace = await freeSpaceIfDue() {
            snapshot.freeSpace = freeSpace
        }
        return snapshot
    }

    public func testConnection() async throws -> String {
        let session = try await rpc("session-get")
        let version = JSON.string(session["version"]) ?? "unknown"
        return "Transmission \(version)"
    }

    // MARK: RPC

    /// Sends one RPC call, handling the `409` session-id handshake on every
    /// request and mapping cause-specific statuses to `ServerFailure`.
    private func rpc(_ method: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: ["method": method, "arguments": arguments, "tag": 1])
        } catch {
            throw ServerFailure.protocolViolation("could not encode \(method) request: \(error.localizedDescription)")
        }

        let url = transport.url(path: "/transmission/rpc")
        let transport = self.transport
        let outcome = try await SessionIdHandshake.run(initialSessionId: sessionId) { currentSessionId in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let currentSessionId {
                request.setValue(currentSessionId, forHTTPHeaderField: SessionIdHandshake.headerField)
            }
            request.httpBody = body
            return try await transport.send(request)
        }
        sessionId = outcome.sessionId

        let response = outcome.response
        switch response.statusCode {
        case 200:
            break
        case 401:
            throw ServerFailure.auth("Transmission authentication failed")
        case 403:
            throw ServerFailure.serverError("this IP is not allowed by rpc-whitelist, or it is temporarily locked out after failed auth attempts")
        case 409:
            throw ServerFailure.serverError("Transmission kept rejecting the RPC session id")
        case 421:
            throw ServerFailure.serverError("host not in rpc-host-whitelist — add it to rpc-host-whitelist or connect by IP address")
        default:
            throw ServerFailure.serverError("Transmission RPC returned HTTP \(response.statusCode)")
        }

        let root = try JSON.object(response.body)
        if let result = root["result"] as? String, result != "success" {
            throw ServerFailure.serverError(result)
        }
        guard let arguments = root["arguments"] as? [String: Any] else {
            throw ServerFailure.protocolViolation("\(method): response is missing arguments")
        }
        return arguments
    }

    // MARK: Free space (slow cadence)

    /// Fetches free space at most once per `freeSpaceRefreshInterval`.
    /// Failures are swallowed: free space is optional and must never fail the
    /// speed poll.
    private func freeSpaceIfDue(now: Date = Date()) async -> Int64? {
        if let last = lastFreeSpaceFetch, now.timeIntervalSince(last) < Self.freeSpaceRefreshInterval {
            return cachedFreeSpace
        }
        do {
            if downloadDirectory == nil {
                let session = try await rpc("session-get")
                downloadDirectory = JSON.string(session["download-dir"])
            }
            guard let path = downloadDirectory else {
                lastFreeSpaceFetch = now
                cachedFreeSpace = nil
                return nil
            }
            let arguments = try await rpc("free-space", arguments: ["path": path])
            let size = TransmissionParser.freeSpace(fromArguments: arguments)
            cachedFreeSpace = size
            lastFreeSpaceFetch = now
            return size
        } catch {
            lastFreeSpaceFetch = now
            cachedFreeSpace = nil
            return nil
        }
    }
}
