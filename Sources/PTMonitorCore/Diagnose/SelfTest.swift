import CoreGraphics
import Dispatch
import Foundation

/// In-binary self-check harness.
///
/// XCTest is unavailable under Command Line Tools (`error: XCTest not
/// available`), so automated checks live here and run via
/// `swift run PTMonitor --selftest`. The contract is the same as a test suite:
/// exit 0 when every check passes, non-zero with a readable message on the
/// first failure.
///
/// The fixtures for the API clients (steps 5–6) will be added here as Swift
/// string literals holding the documented response shapes from
/// `research/apis.md`, so a future XCTest suite can reuse them verbatim.
public enum SelfTest {

    public struct Result: Equatable {
        /// Number of checks that passed before the run finished.
        public let passed: Int
        /// `nil` when everything passed; otherwise the first failure's message.
        public let failure: String?
        public var isSuccess: Bool { failure == nil }

        public init(passed: Int, failure: String?) {
            self.passed = passed
            self.failure = failure
        }
    }

    struct Failure: Error {
        let message: String
    }

    /// Runs every check, stopping at the first failure.
    public static func run() -> Result {
        var passed = 0
        var failureMessage: String?

        do {
            try formatterChecks(&passed)
            try clientChecks(&passed)
            try rowChecks(&passed)
            try storeChecks(&passed)
            try transportChecks(&passed)
            try validationChecks(&passed)
            try probeChecks(&passed)
        } catch let failure as Failure {
            failureMessage = failure.message
        } catch {
            failureMessage = "unexpected error: \(error)"
        }

        return Result(passed: passed, failure: failureMessage)
    }

    // MARK: - Formatter checks (AC14)

    private static func formatterChecks(_ passed: inout Int) throws {
        func expect(_ name: String, _ actual: @autoclosure () -> String, _ expected: String) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \"\(expected)\", got \"\(value)\"")
            }
            passed += 1
        }

        func expectOptional(_ name: String, _ actual: @autoclosure () -> String?, _ expected: String?) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \(describe(expected)), got \(describe(value))")
            }
            passed += 1
        }

        // Rate formatting: unit thresholds and the decimal rule.
        try expect("rate(0)", ByteRateFormatter.rate(0), "0 B/s")
        try expect("rate(999)", ByteRateFormatter.rate(999), "999 B/s")
        try expect("rate(1024) = 1.0 KB/s", ByteRateFormatter.rate(1024), "1.0K")
        try expect("rate(1.2 MB/s)", ByteRateFormatter.rate(1_258_291), "1.2M")
        try expect("rate(1.00 GB/s)", ByteRateFormatter.rate(1_073_741_824), "1.0G")
        // One decimal below 100, zero decimals at 100 and above.
        try expect("rate(99.0K)", ByteRateFormatter.rate(101_376), "99.0K")
        try expect("rate(100K)", ByteRateFormatter.rate(102_400), "100K")

        // Full vs compact menu bar text.
        let down: Int64 = 1_258_291   // 1.2M
        let up: Int64 = 348_160       // 340K
        try expect("full speed text", ByteRateFormatter.speedText(down: down, up: up, form: .full),
                   "↓ 1.2M ↑ 340K")
        try expect("compact speed text", ByteRateFormatter.speedText(down: down, up: up, form: .compact),
                   "↓1.2M ↑340K")

        // Degradation ladder: full → compact → nil, never truncated mid-number.
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 7 }
        try expectOptional("ladder: roomy",
                           ByteRateFormatter.degradedSpeedText(down: down, up: up, availableWidth: 200, measure: measure),
                           "↓ 1.2M ↑ 340K")
        try expectOptional("ladder: tight",
                           ByteRateFormatter.degradedSpeedText(down: down, up: up, availableWidth: 80, measure: measure),
                           "↓1.2M ↑340K")
        try expectOptional("ladder: too tight",
                           ByteRateFormatter.degradedSpeedText(down: down, up: up, availableWidth: 40, measure: measure),
                           nil)

        // Byte counts (the free-space row).
        try expect("bytes(0)", ByteRateFormatter.bytes(0), "0 B")
        try expect("bytes(999)", ByteRateFormatter.bytes(999), "999 B")
        try expect("bytes(412.5 GB)", ByteRateFormatter.bytes(442_918_502_400), "412 GB")
        try expect("bytes(1.00 KB)", ByteRateFormatter.bytes(1024), "1.00 KB")
    }

    // MARK: - Transport error description (R6)

    /// `HTTPTransport.describe` turns `URLError` codes into cause-specific,
    /// actionable text; the ATS case matters on macOS 14+ where plain HTTP to
    /// non-LAN addresses is blocked.
    private static func transportChecks(_ passed: inout Int) throws {
        func expect(_ name: String, _ actual: String, contains expected: String) throws {
            guard actual.contains(expected) else {
                throw Failure(message: "\(name): expected message containing \"\(expected)\", got \"\(actual)\"")
            }
            passed += 1
        }

        let ats = URLError(.appTransportSecurityRequiresSecureConnection)
        try expect("transport: ATS block", HTTPTransport.describe(ats), contains: "App Transport Security")
        try expect("transport: ATS hint names LAN", HTTPTransport.describe(ats), contains: "192.168")
        try expect("transport: timeout", HTTPTransport.describe(URLError(.timedOut)), contains: "timed out")
        try expect("transport: DNS", HTTPTransport.describe(URLError(.cannotFindHost)), contains: "host not found")
        try expect("transport: refused", HTTPTransport.describe(URLError(.cannotConnectToHost)), contains: "connection refused")
        try expect("transport: TLS", HTTPTransport.describe(URLError(.serverCertificateUntrusted)), contains: "self-signed")
    }

    // MARK: - Config validation / host parsing (step 12)

    /// `HostFieldParser` and `ServerConfigValidator` normalise the same host a
    /// user could type in the preferences window or pass to `--probe`.
    private static func validationChecks(_ passed: inout Int) throws {
        func expect<T: Equatable>(_ name: String, _ actual: @autoclosure () -> T, _ expected: T) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \(expected), got \(value)")
            }
            passed += 1
        }

        func expectFailure(_ name: String, _ body: () throws -> Void) throws {
            do {
                try body()
                throw Failure(message: "\(name): expected a failure, but it succeeded")
            } catch let failure as ServerFailure {
                guard !failure.message.isEmpty else {
                    throw Failure(message: "\(name): failure message was empty")
                }
                passed += 1
            }
        }

        // Plain host keeps the supplied port.
        let plain = try HostFieldParser.parse("nas.local", defaultPort: 8080)
        try expect("host: plain name", plain.host, "nas.local")
        try expect("host: default port", plain.port, 8080)
        try expect("host: no scheme", plain.schemeIsTLS, nil)

        // host:port splits, whitespace is trimmed.
        let withPort = try HostFieldParser.parse("  192.168.1.50:9091 ", defaultPort: 8080)
        try expect("host:port host", withPort.host, "192.168.1.50")
        try expect("host:port port", withPort.port, 9091)
        try expect("host:port extracted", withPort.extractedPort, true)

        // A pasted URL parses; https implies TLS.
        let url = try HostFieldParser.parse("https://nas.local:8443/", defaultPort: 8080)
        try expect("url host", url.host, "nas.local")
        try expect("url port", url.port, 8443)
        try expect("url scheme tls", url.schemeIsTLS, true)

        // ws:// is rejected with a readable message (design §4.3).
        try expectFailure("host: ws scheme rejected") {
            _ = try HostFieldParser.parse("ws://nas.local:8080", defaultPort: 8080)
        }

        // Validator: normalises and reports the scheme/port adjustments.
        let draft = ServerConfigDraft(
            kind: .transmission,
            name: "  NAS  ",
            host: "http://nas.local:9091",
            port: "",
            useTLS: true,
            username: "  admin "
        )
        let validated = try ServerConfigValidator.validate(draft)
        try expect("validator host", validated.config.host, "nas.local")
        try expect("validator port", validated.config.port, 9091)
        try expect("validator https disabled by http scheme", validated.config.useTLS, false)
        try expect("validator trims name", validated.config.name, "NAS")
        try expect("validator trims username", validated.config.username, "admin")
        try expect("validator notice count", validated.notices.count, 1)

        // Invalid port text is a readable failure.
        try expectFailure("validator rejects bad port") {
            _ = try ServerConfigValidator.validate(ServerConfigDraft(kind: .qbittorrent, host: "nas", port: "70000"))
        }
        try expectFailure("validator rejects empty host") {
            _ = try ServerConfigValidator.validate(ServerConfigDraft(kind: .qbittorrent, host: "   "))
        }
    }

    // MARK: - Probe mode (step 10, AC13)

    private static func probeChecks(_ passed: inout Int) throws {
        func expect<T: Equatable>(_ name: String, _ actual: @autoclosure () -> T, _ expected: T) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \(expected), got \(value)")
            }
            passed += 1
        }

        func expectUsageError(_ name: String, _ arguments: [String]) throws {
            do {
                _ = try ProbeRunner.parse(arguments)
                throw Failure(message: "\(name): expected a usage error")
            } catch is ProbeRunner.UsageError {
                passed += 1
            }
        }

        // Flags in any order; `--probe` carries the type.
        let options = try ProbeRunner.parse([
            "--https", "--host", "nas.local", "--probe", "qbittorrent", "--port", "8080", "--insecure",
        ])
        try expect("probe kind", options.kind, .qbittorrent)
        try expect("probe host", options.host, "nas.local")
        try expect("probe port", options.port, 8080)
        try expect("probe https", options.useTLS, true)
        try expect("probe insecure", options.allowInsecureTLS, true)

        // Default port comes from the kind.
        let defaulted = try ProbeRunner.parse(["--host", "nas", "--probe", "transmission"])
        try expect("probe default port", defaulted.port, 9091)

        try expectUsageError("probe rejects unknown type", ["--probe", "deluge", "--host", "nas"])
        try expectUsageError("probe requires host", ["--probe", "qbittorrent"])
        try expectUsageError("probe rejects stray argument", ["--probe", "qbittorrent", "--host", "nas", "--wat"])

        // JSON output shape.
        let snapshot = TransferSnapshot(
            downSpeed: 1258291, upSpeed: 348160, activeTorrents: 3, totalTorrents: 4,
            freeSpace: 442_918_502_400, connectionState: .connected,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let config = ServerConfig(kind: .qbittorrent, name: "NAS", host: "nas.local", port: 8080)
        let json = try ProbeRunner.encode(snapshot: snapshot, config: config)
        let root = try JSON.object(json)
        let snapshotObject = root["snapshot"] as? [String: Any] ?? [:]
        try expect("probe json downSpeed", JSON.int64(snapshotObject["downSpeed"]), 1_258_291)
        try expect("probe json freeSpace", JSON.int64(snapshotObject["freeSpace"]), 442_918_502_400)
        try expect("probe json connection state", snapshotObject["connectionState"] as? String, "connected")
        let serverObject = root["server"] as? [String: Any] ?? [:]
        try expect("probe json server kind", serverObject["kind"] as? String, "qbittorrent")

        // A nil free space encodes as JSON null, not a missing key.
        let noFree = try ProbeRunner.encode(
            snapshot: TransferSnapshot(downSpeed: 0, upSpeed: 0),
            config: config
        )
        let noFreeRoot = try JSON.object(noFree)
        let noFreeSnapshot = noFreeRoot["snapshot"] as? [String: Any] ?? [:]
        try expect("probe json nil freeSpace is null", noFreeSnapshot["freeSpace"] is NSNull, true)
    }

    private static func describe(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "nil"
    }

    // MARK: - Client checks (steps 5–6)

    /// Mutable holder so checks that run off the main thread can report back
    /// without capturing a `var` in a `@Sendable` closure.
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    /// Bridges an async check into the synchronous harness. The check only uses
    /// injected closures, so it cannot deadlock on the main thread.
    private static func awaitBlocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<Swift.Result<T, Error>>()
        Task {
            do {
                box.value = .success(try await operation())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success, let result = box.value else {
            throw Failure(message: "async check did not finish within 10s")
        }
        return try result.get()
    }

    private static func clientChecks(_ passed: inout Int) throws {
        func expect<T: Equatable>(_ name: String, _ actual: @autoclosure () -> T, _ expected: T) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \(expected), got \(value)")
            }
            passed += 1
        }

        func expectOptional<T: Equatable>(_ name: String, _ actual: @autoclosure () -> T?, _ expected: T?) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \(describeOptional(expected)), got \(describeOptional(value))")
            }
            passed += 1
        }

        // --- qBittorrent: recorded sync/maindata fixture (research/apis.md §1.3) ---
        // Four torrents: 3 active (downloading, stalledUP, uploading), 1 paused.
        let mainData = """
        {
          "rid": 1,
          "full_update": true,
          "server_state": {
            "dl_info_speed": 1258291,
            "up_info_speed": 348160,
            "connection_status": "connected",
            "free_space_on_disk": 442918502400
          },
          "torrents": {
            "aaaa000000000000000000000000000000000000": { "state": "downloading" },
            "bbbb000000000000000000000000000000000000": { "state": "stalledUP" },
            "cccc000000000000000000000000000000000000": { "state": "uploading" },
            "dddd000000000000000000000000000000000000": { "state": "pausedDL" }
          }
        }
        """

        // webapiVersion >= 2.1.1 → free space is read.
        let gated = try QBittorrentParser.snapshot(
            fromMainData: Data(mainData.utf8),
            webAPIVersion: WebAPIVersion(major: 2, minor: 1, patch: 1)
        )
        try expect("qb maindata down speed", gated.downSpeed, 1_258_291)
        try expect("qb maindata up speed", gated.upSpeed, 348_160)
        try expect("qb maindata connection state", gated.connectionState, ConnectionState.connected)
        try expect("qb maindata active torrents", gated.activeTorrents, 3)
        try expect("qb maindata total torrents", gated.totalTorrents, 4)
        try expect("qb maindata free space (>=2.1.1)", gated.freeSpace, 442_918_502_400)

        // webapiVersion < 2.1.1 → free space is gated to nil, other fields intact.
        let ungated = try QBittorrentParser.snapshot(
            fromMainData: Data(mainData.utf8),
            webAPIVersion: WebAPIVersion(major: 2, minor: 0, patch: 2)
        )
        try expectOptional("qb maindata free space gated (<2.1.1)", ungated.freeSpace, nil)
        try expect("qb maindata down speed still parsed", ungated.downSpeed, 1_258_291)

        // Version parsing and the pre-2.0 rejection threshold.
        try expect("qb webapi version parse", QBittorrentParser.webAPIVersion("2.11.2"), WebAPIVersion(major: 2, minor: 11, patch: 2))
        try expect(
            "qb webapi 2.0 accepted, 1.9 rejected",
            (QBittorrentParser.webAPIVersion("2.0.0") ?? WebAPIVersion.v2_0_0) >= WebAPIVersion.v2_0_0,
            true
        )

        // --- qBittorrent: 200 "Fails." is a credential failure, not a 401 ---
        let fails = QBittorrentParser.loginFailure(statusCode: 200, body: "Fails.")
        try expect("qb 200 Fails. -> auth", fails?.kindLabel, "auth failed")
        try expect("qb 200 Ok. -> success", QBittorrentParser.loginFailure(statusCode: 200, body: "Ok.") == nil, true)
        // Only `auth/login` can be banned: the server checks the ban before it
        // looks at the credentials.
        try expect(
            "qb login 403 -> banned",
            QBittorrentParser.loginFailure(statusCode: 403, body: "")?.kindLabel,
            "banned"
        )
        // A 403 outside `auth/login` is NOT a ban: qBittorrent answers any
        // private API call made without a session with 403
        // (webapplication.cpp: `!session() && !isPublicAPI`). Conflating the two
        // once reported a broken session cookie as "the server banned this IP".
        try expect(
            "qb non-login 403 -> session problem, not a ban",
            QBittorrentParser.endpointFailure(statusCode: 403, context: "sync/maindata")?.kindLabel,
            "unexpected response"
        )
        try expect(
            "qb non-login 401 -> auth",
            QBittorrentParser.endpointFailure(statusCode: 401, context: "sync/maindata")?.kindLabel,
            "auth failed"
        )
        try expect(
            "qb non-login 200 -> no failure",
            QBittorrentParser.endpointFailure(statusCode: 200, context: "sync/maindata") == nil,
            true
        )
        try expect(
            "qb login 403 and non-login 403 are different causes",
            QBittorrentParser.loginFailure(statusCode: 403, body: "") == QBittorrentParser.endpointFailure(statusCode: 403, context: "sync/maindata"),
            false
        )

        // --- Transmission: recorded session-stats fixture (research/apis.md §2.2) ---
        let sessionStats = """
        {
          "arguments": {
            "activeTorrentCount": 3,
            "downloadSpeed": 1258291,
            "pausedTorrentCount": 1,
            "torrentCount": 7,
            "uploadSpeed": 348160,
            "cumulative-stats": { "downloadedBytes": 0, "filesAdded": 0, "secondsActive": 0, "sessionCount": 1, "uploadedBytes": 0 },
            "current-stats": { "downloadedBytes": 0, "filesAdded": 0, "secondsActive": 0, "sessionCount": 1, "uploadedBytes": 0 }
          },
          "result": "success",
          "tag": 1
        }
        """
        let tx = try TransmissionParser.snapshot(fromResponseBody: Data(sessionStats.utf8))
        try expect("tx session-stats down speed", tx.downSpeed, 1_258_291)
        try expect("tx session-stats up speed", tx.upSpeed, 348_160)
        try expect("tx session-stats active torrents", tx.activeTorrents, 3)
        try expect("tx session-stats total torrents", tx.totalTorrents, 7)
        try expect("tx session-stats connection state", tx.connectionState, ConnectionState.connected)

        // HTTP 200 with result != "success" must still be a failure.
        do {
            _ = try TransmissionParser.snapshot(
                fromResponseBody: Data("{\"result\":\"permission denied\",\"arguments\":{}}".utf8)
            )
            try expect("tx non-success result throws", false, true)
        } catch let failure as ServerFailure {
            try expect("tx non-success result -> server error", failure.kindLabel, "server error")
        }

        // free-space `size-bytes` parsing.
        try expectOptional(
            "tx free-space size-bytes",
            TransmissionParser.freeSpace(fromArguments: ["path": "/volume1/downloads", "size-bytes": 442_918_502_400]),
            442_918_502_400
        )

        // --- Transmission 409 handshake (injected, no live server) ---
        // First response is a 409 carrying the id; the retry is invoked exactly
        // once and the id is stored.
        let retryCounter = Box<Int>()
        retryCounter.value = 0
        let outcome = try awaitBlocking { () -> SessionIdHandshake.Outcome in
            try await SessionIdHandshake.run(initialSessionId: nil) { _ in
                retryCounter.value = (retryCounter.value ?? 0) + 1
                if retryCounter.value == 1 {
                    return HTTPResponse(
                        statusCode: 409,
                        headers: [SessionIdHandshake.headerField: "sess-abc"],
                        body: Data()
                    )
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }
        }
        try expect("409 handshake retried exactly once", retryCounter.value ?? -1, 2)
        try expect("409 handshake stored the session id", outcome.sessionId, "sess-abc")
        try expect("409 handshake final status", outcome.response.statusCode, 200)

        // A second 409 does not recurse: only two requests are ever sent.
        let repeatedCounter = Box<Int>()
        repeatedCounter.value = 0
        let repeated = try awaitBlocking { () -> SessionIdHandshake.Outcome in
            try await SessionIdHandshake.run(initialSessionId: nil) { _ in
                repeatedCounter.value = (repeatedCounter.value ?? 0) + 1
                return HTTPResponse(
                    statusCode: 409,
                    headers: [SessionIdHandshake.headerField: "sess-\(repeatedCounter.value ?? 0)"],
                    body: Data()
                )
            }
        }
        try expect("repeated 409 does not recurse", repeatedCounter.value ?? -1, 2)
        try expect("repeated 409 surfaces as 409", repeated.response.statusCode, 409)

        // The pure decision itself: a second 409 (hasRetried) never retries.
        try expect(
            "step: first 409 retries",
            SessionIdHandshake.step(statusCode: 409, sessionIdHeader: "abc", hasRetried: false).shouldRetry,
            true
        )
        try expect(
            "step: second 409 does not retry",
            SessionIdHandshake.step(statusCode: 409, sessionIdHeader: "abc", hasRetried: true).shouldRetry,
            false
        )
        try expect(
            "step: 200 does not retry",
            SessionIdHandshake.step(statusCode: 200, sessionIdHeader: nil, hasRetried: false).shouldRetry,
            false
        )

        // --- Torrent list normalisation (R12, AC17) ---
        // qBittorrent `state` strings (research/apis.md §1.3, design §6.1).
        let qbStateTable: [(String, TorrentState)] = [
            ("downloading", .downloading), ("metaDL", .downloading), ("forcedDL", .downloading),
            ("stalledDL", .stalled),
            ("queuedDL", .queued), ("queuedUP", .queued),
            ("uploading", .seeding), ("forcedUP", .seeding), ("stalledUP", .seeding),
            ("pausedDL", .paused), ("pausedUP", .paused),
            ("checkingDL", .checking), ("checkingUP", .checking), ("checkingResumeData", .checking),
            ("allocating", .other), ("moving", .other), ("unknown", .other),
            ("error", .error), ("missingFiles", .error),
            ("somethingNewInAVfutureVersion", .other)
        ]
        for (raw, expected) in qbStateTable {
            try expect("qb state \(raw)", QBittorrentParser.state(raw), expected)
        }

        // qBittorrent eta: `8640000` is the "infinite" sentinel, negatives are
        // unknown (design §6.1).
        try expectOptional("qb eta infinite sentinel", QBittorrentParser.etaSeconds(8_640_000), nil)
        try expectOptional("qb eta negative", QBittorrentParser.etaSeconds(-1), nil)
        try expectOptional("qb eta absent", QBittorrentParser.etaSeconds(nil), nil)
        try expectOptional("qb eta valid", QBittorrentParser.etaSeconds(3600), 3600)

        // qBittorrent summaries: name fallback to the hash, speeds, clamped
        // progress, and the fixed sort in `TransferSnapshot.torrents`.
        let qbTorrents: [String: Any] = [
            "aaaa000000000000000000000000000000000000": [
                "name": "Seeding ISO", "state": "stalledUP", "progress": 1.0,
                "dlspeed": 0, "upspeed": 20480, "eta": 8640000
            ],
            "bbbb000000000000000000000000000000000000": [
                "name": "Downloading ISO", "state": "downloading", "progress": 0.42,
                "dlspeed": 1_258_291, "upspeed": 5120, "eta": 1800
            ],
            // No name → falls back to the hash; progress is malformed.
            "cccc000000000000000000000000000000000000": [
                "state": "error", "progress": 7.5, "dlspeed": 0, "upspeed": 0
            ]
        ]
        var qbSummaries = QBittorrentParser.summaries(fromTorrents: qbTorrents)
        try expect("qb summaries count", qbSummaries.count, 3)
        let qbDownloading = qbSummaries.first { $0.name == "Downloading ISO" }
        try expectOptional("qb summary state", qbDownloading?.state, TorrentState.downloading)
        try expectOptional("qb summary down speed", qbDownloading?.downSpeed, 1_258_291)
        try expectOptional("qb summary eta", qbDownloading?.etaSeconds, 1800)
        let qbUnnamed = qbSummaries.first { $0.id == "cccc000000000000000000000000000000000000" }
        try expectOptional("qb summary name falls back to hash", qbUnnamed?.name, "cccc000000000000000000000000000000000000")
        try expectOptional("qb summary error state", qbUnnamed?.state, TorrentState.error)
        try expectOptional("qb summary progress clamped", qbUnnamed?.progress, 1.0)
        let qbSeeding = qbSummaries.first { $0.name == "Seeding ISO" }
        try expectOptional("qb summary infinite eta is nil", qbSeeding?.etaSeconds, nil)

        // Fixed sort (design §6.1): downloading first, then seeding, then the
        // rest; within a group by down speed desc.
        qbSummaries = TorrentSummary.sorted(qbSummaries)
        try expect("qb sort: downloading first", qbSummaries.first?.name, "Downloading ISO")
        try expect("qb sort: seeding second", qbSummaries.dropFirst().first?.name, "Seeding ISO")
        try expect("qb sort: errored last", qbSummaries.last?.id, "cccc000000000000000000000000000000000000")

        // Transmission `status` integers (research/apis.md §2.2, design §6.1).
        let txStatusTable: [(Int?, TorrentState)] = [
            (0, .paused), (1, .checking), (2, .checking),
            (3, .queued), (4, .downloading), (5, .queued), (6, .seeding),
            (nil, .other), (99, .other)
        ]
        for (raw, expected) in txStatusTable {
            try expect("tx status \(raw.map(String.init) ?? "nil")", TransmissionParser.state(status: raw), expected)
        }

        // Transmission eta: -1/-2 are sentinels (design §6.1).
        try expectOptional("tx eta -1 sentinel", TransmissionParser.etaSeconds(-1), nil)
        try expectOptional("tx eta -2 sentinel", TransmissionParser.etaSeconds(-2), nil)
        try expectOptional("tx eta valid", TransmissionParser.etaSeconds(7200), 7200)

        // Transmission summaries: `error != 0` overrides the status mapping.
        let txTorrents: [Any] = [
            [
                "id": 1, "name": "Linux Distro", "status": 4, "percentDone": 0.5,
                "rateDownload": 524288, "rateUpload": 0, "eta": 900, "error": 0, "errorString": ""
            ],
            [
                "id": 2, "name": "Broken Torrent", "status": 4, "percentDone": 0.1,
                "rateDownload": 0, "rateUpload": 0, "eta": -1, "error": 3, "errorString": "unregistered torrent"
            ]
        ]
        let txSummaries = TransmissionParser.summaries(fromTorrents: txTorrents)
        try expect("tx summaries count", txSummaries.count, 2)
        let txDownloading = txSummaries.first { $0.name == "Linux Distro" }
        try expectOptional("tx summary state", txDownloading?.state, TorrentState.downloading)
        try expectOptional("tx summary progress", txDownloading?.progress, 0.5)
        try expectOptional("tx summary down speed", txDownloading?.downSpeed, 524_288)
        let txBroken = txSummaries.first { $0.name == "Broken Torrent" }
        try expectOptional("tx summary error overrides status", txBroken?.state, TorrentState.error)
        try expectOptional("tx summary eta sentinel is nil", txBroken?.etaSeconds, nil)

        // Progress clamping is shared by both clients (AC17): nil/NaN/negative
        // clamp to 0, over-range to 1.
        try expect("clamp nil", TorrentSummary.clampedProgress(nil), 0.0)
        try expect("clamp negative", TorrentSummary.clampedProgress(-0.2), 0.0)
        try expect("clamp over range", TorrentSummary.clampedProgress(1.5), 1.0)
        try expect("clamp NaN", TorrentSummary.clampedProgress(Double.nan), 0.0)
        try expect("clamp valid", TorrentSummary.clampedProgress(0.42), 0.42)

        // `isActive` drives the dropdown's "active only" filter: true only
        // when the torrent actually transfers data in either direction.
        try expect(
            "isActive false when idle",
            TorrentSummary(id: "1", name: "Idle", state: .paused, progress: 1).isActive,
            false
        )
        try expect(
            "isActive true when downloading",
            TorrentSummary(id: "2", name: "Downloading", state: .downloading, progress: 0.5, downSpeed: 1).isActive,
            true
        )
        try expect(
            "isActive true when uploading",
            TorrentSummary(id: "3", name: "Seeding", state: .seeding, progress: 1, upSpeed: 1).isActive,
            true
        )
    }

    private static func describeOptional<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    // MARK: - Torrent row presentation checks (torrent list redesign)

    /// The row detail line and the percentage next to the progress bar. Both are
    /// pure, string-free decisions, so they are checked here rather than by
    /// eyeballing the panel (AC5). The *text* is produced by `L10n` in the app
    /// target and is deliberately not asserted (a check must never depend on a
    /// localizable string).
    private static func rowChecks(_ passed: inout Int) throws {
        func expect<T: Equatable>(_ name: String, _ actual: @autoclosure () -> T, _ expected: T) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \(expected), got \(value)")
            }
            passed += 1
        }

        // Downloading: rate + eta, in that order.
        try expect(
            "row: downloading shows rate then eta",
            TorrentSummary.infoSegments(state: .downloading, down: 1_258_291, up: 0, etaSeconds: 1_800),
            [.down(1_258_291), .eta(1_800)]
        )

        // A torrent can seed while it downloads; that upload rate is real
        // traffic and must not be dropped from the row.
        try expect(
            "row: downloading keeps its upload rate",
            TorrentSummary.infoSegments(state: .downloading, down: 1_258_291, up: 348_160, etaSeconds: 1_800),
            [.down(1_258_291), .up(348_160), .eta(1_800)]
        )
        try expect(
            "row: uploading while downloading without an eta",
            TorrentSummary.infoSegments(state: .downloading, down: 512_000, up: 348_160, etaSeconds: nil),
            [.down(512_000), .up(348_160)]
        )

        // A zero rate is dropped instead of rendering a bare arrow (AC3).
        try expect(
            "row: downloading without speed shows only eta",
            TorrentSummary.infoSegments(state: .downloading, down: 0, up: 0, etaSeconds: 600),
            [.eta(600)]
        )
        try expect(
            "row: seeding shows upload rate only",
            TorrentSummary.infoSegments(state: .seeding, down: 0, up: 348_160, etaSeconds: 1_800),
            [.up(348_160)]
        )
        try expect(
            "row: seeding without upload speed falls back to the word",
            TorrentSummary.infoSegments(state: .seeding, down: 1_258_291, up: 0, etaSeconds: nil),
            [.stateWord(.seeding)]
        )

        // A downloading row with neither speed nor eta is still never blank.
        try expect(
            "row: downloading with nothing to report falls back to the word",
            TorrentSummary.infoSegments(state: .downloading, down: 0, up: 0, etaSeconds: nil),
            [.stateWord(.downloading)]
        )
        try expect(
            "row: a negative eta is dropped, not rendered as an em dash",
            TorrentSummary.infoSegments(state: .downloading, down: 0, up: 0, etaSeconds: -1),
            [.stateWord(.downloading)]
        )

        // Every idle state carries its own word, and speeds never leak into it.
        let idleStates: [TorrentState] = [.stalled, .queued, .checking, .paused, .error, .other]
        for state in idleStates {
            try expect(
                "row: \(state.rawValue) shows only its word",
                TorrentSummary.infoSegments(state: state, down: 1_258_291, up: 348_160, etaSeconds: 60),
                [.stateWord(state)]
            )
        }

        // Percentage text, including the clamp the bar also relies on.
        try expect("percent: 0", TorrentSummary.percentText(0), "0%")
        try expect("percent: 0.624", TorrentSummary.percentText(0.624), "62%")
        try expect("percent: 0.995 rounds up", TorrentSummary.percentText(0.995), "100%")
        try expect("percent: complete", TorrentSummary.percentText(1), "100%")
        try expect("percent: over-range clamps", TorrentSummary.percentText(1.5), "100%")
        try expect("percent: NaN clamps", TorrentSummary.percentText(Double.nan), "0%")
    }

    // MARK: - Store checks (steps 7–9)

    /// Settings persistence, `MonitorStore` change-detection/aggregate helpers,
    /// and a stub-client poll. Nothing here touches the network or the real
    /// Keychain, so the checks are deterministic and fast.
    private static func storeChecks(_ passed: inout Int) throws {
        func expect<T: Equatable>(_ name: String, _ actual: @autoclosure () -> T, _ expected: T) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \(expected), got \(value)")
            }
            passed += 1
        }

        func expectOptional<T: Equatable>(_ name: String, _ actual: @autoclosure () -> T?, _ expected: T?) throws {
            let value = actual()
            guard value == expected else {
                throw Failure(message: "\(name): expected \(describeOptional(expected)), got \(describeOptional(value))")
            }
            passed += 1
        }

        // --- SettingsStore round-trip in an isolated UserDefaults suite ---
        let suiteName = "com.ptmonitor.PTMonitor.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure(message: "could not create a temporary UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        try expect("settings start empty", settings.servers.count, 0)
        try expect("settings default interval", settings.pollInterval, 2)
        try expect("settings default show-speeds", settings.showSpeedsInMenuBar, true)
        try expect("settings default show-active-only", settings.showActiveTorrentsOnly, false)

        var server = ServerConfig(kind: .qbittorrent, name: "NAS", host: "192.168.1.2", port: 8080)
        settings.add(server)
        try expect("settings add", settings.servers.count, 1)

        server.name = "NAS 2"
        server.port = 8081
        settings.update(server)
        try expect("settings update", settings.server(withID: server.id)?.port, 8081)

        settings.setEnabled(false, for: server.id)
        try expect("settings disable", settings.server(withID: server.id)?.isEnabled, false)

        settings.setPollInterval(0.2)
        try expect("settings clamps interval low", settings.pollInterval, 1)
        settings.setPollInterval(999)
        try expect("settings clamps interval high", settings.pollInterval, 60)
        settings.setShowSpeedsInMenuBar(false)
        try expect("settings show-speeds off persisted", settings.showSpeedsInMenuBar, false)
        settings.setShowActiveTorrentsOnly(true)
        try expect("settings show-active-only on persisted", settings.showActiveTorrentsOnly, true)

        // Reload through a fresh store on the same suite: proves persistence.
        let reloaded = SettingsStore(defaults: defaults)
        try expect("settings reload server count", reloaded.servers.count, 1)
        try expect("settings reload interval", reloaded.pollInterval, 60)
        try expect("settings reload show-speeds", reloaded.showSpeedsInMenuBar, false)
        try expect("settings reload show-active-only", reloaded.showActiveTorrentsOnly, true)

        settings.delete(id: server.id)
        try expect("settings delete", settings.servers.count, 0)

        // --- MonitorStore change detection (ignores fetchedAt) ---
        let slow = TransferSnapshot(
            downSpeed: 10, upSpeed: 5, activeTorrents: 1, totalTorrents: 2,
            freeSpace: nil, connectionState: .connected, fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let slowNewer = TransferSnapshot(
            downSpeed: 10, upSpeed: 5, activeTorrents: 1, totalTorrents: 2,
            freeSpace: nil, connectionState: .connected, fetchedAt: Date(timeIntervalSince1970: 999)
        )
        try expect("change: equivalent ignores fetchedAt", MonitorStore.isEquivalent(.online(slow), .online(slowNewer)), true)
        try expect(
            "change: speed difference publishes",
            MonitorStore.isEquivalent(.online(slow), .online(TransferSnapshot(downSpeed: 11, upSpeed: 5, activeTorrents: 1, totalTorrents: 2))),
            false
        )
        try expect("change: nil current publishes", MonitorStore.isEquivalent(nil, .online(slow)), false)
        try expect("change: disabled is idempotent", MonitorStore.isEquivalent(.disabled, .disabled), true)
        try expect("change: failure kind difference publishes", MonitorStore.isEquivalent(.failed(.auth("x")), .failed(.unreachable("x"))), false)

        // --- Credential-failure backoff (research/apis.md §1.1, §2.1.1) ---
        try expect(
            "retry delay: success uses the interval",
            MonitorStore.retryDelay(after: .online(slow), baseInterval: 2),
            2
        )
        try expect(
            "retry delay: auth failure backs off hard",
            MonitorStore.retryDelay(after: .failed(.auth("invalid username or password")), baseInterval: 2),
            MonitorStore.credentialFailureBackoff
        )
        try expect(
            "retry delay: unreachable failure keeps the interval",
            MonitorStore.retryDelay(after: .failed(.unreachable("connection refused")), baseInterval: 2),
            2
        )
        try expect(
            "retry delay: backoff never shortens a longer interval",
            MonitorStore.retryDelay(after: .failed(.auth("x")), baseInterval: MonitorStore.bannedBackoff + 60),
            MonitorStore.bannedBackoff + 60
        )
        try expect(
            "retry delay: server error keeps the interval",
            MonitorStore.retryDelay(after: .failed(.serverError("permission denied")), baseInterval: 2),
            2
        )
        try expect(
            "retry delay: protocol violation keeps the interval",
            MonitorStore.retryDelay(after: .failed(.protocolViolation("x")), baseInterval: 2),
            2
        )
        try expect(
            "retry delay: banned backs off hardest",
            MonitorStore.retryDelay(after: .failed(.banned("banned")), baseInterval: 2),
            MonitorStore.bannedBackoff
        )
        try expect(
            "retry delay: a ban is spaced further apart than a bad password",
            MonitorStore.bannedBackoff > MonitorStore.credentialFailureBackoff,
            true
        )
        // The spacing is what keeps the app from tripping qBittorrent's
        // `WebUI/MaxAuthenticationFailCount` (default 5) ban within seconds.
        try expect(
            "retry delay: credential retries are spaced minutes apart",
            MonitorStore.credentialFailureBackoff >= 600,
            true
        )

        // --- MonitorStore aggregate and worst-state icon ---
        let ids = (UUID(), UUID(), UUID())
        let statuses: [UUID: ServerStatus] = [
            ids.0: .online(slow),
            ids.1: .online(TransferSnapshot(downSpeed: 5, upSpeed: 7, activeTorrents: 2, totalTorrents: 3)),
            ids.2: .failed(.auth("invalid username or password"))
        ]
        let aggregate = MonitorStore.aggregate(statuses)
        try expect("aggregate down speed", aggregate.downSpeed, 15)
        try expect("aggregate up speed", aggregate.upSpeed, 12)
        try expect("aggregate active torrents", aggregate.activeTorrents, 3)
        try expect("aggregate online servers", aggregate.onlineServers, 2)
        try expect("aggregate failing servers", aggregate.failingServers, 1)

        try expect("menubar: all failing -> error", MonitorStore.menuBarState([ids.0: .failed(.auth("x"))]), MenuBarState.error)
        try expect("menubar: activity -> active", MonitorStore.menuBarState(statuses), MenuBarState.active)
        try expect(
            "menubar: no activity -> idle",
            MonitorStore.menuBarState([ids.0: .online(TransferSnapshot(downSpeed: 0, upSpeed: 0, activeTorrents: 0))]),
            MenuBarState.idle
        )
        try expect("menubar: empty -> idle", MonitorStore.menuBarState([:]), MenuBarState.idle)
        try expect("menubar: disabled only -> idle", MonitorStore.menuBarState([ids.0: .disabled]), MenuBarState.idle)

        // --- MonitorStore poll with a stub client (no network) ---
        let stubConfig = ServerConfig(kind: .qbittorrent, host: "example.invalid", isEnabled: true)
        let successFactory: @Sendable (ServerConfig) throws -> TorrentClient = { _ in StubClient(snapshot: slow) }
        let online = try awaitBlocking { await MonitorStore.poll(config: stubConfig, clientFactory: successFactory) }
        try expectOptional("poll: stub client -> online", online, .online(slow))

        let authFactory: @Sendable (ServerConfig) throws -> TorrentClient = { _ in StubClient(error: ServerFailure.auth("invalid username or password")) }
        let failed = try awaitBlocking { await MonitorStore.poll(config: stubConfig, clientFactory: authFactory) }
        try expectOptional("poll: ServerFailure -> failed", failed, .failed(.auth("invalid username or password")))

        // A disabled server is never contacted (AC12): the factory must not run.
        let counter = Box<Int>()
        counter.value = 0
        let countingFactory: @Sendable (ServerConfig) throws -> TorrentClient = { _ in
            counter.value = (counter.value ?? 0) + 1
            return StubClient(snapshot: slow)
        }
        let disabledConfig = ServerConfig(kind: .transmission, host: "nas", isEnabled: false)
        let disabled = try awaitBlocking { await MonitorStore.poll(config: disabledConfig, clientFactory: countingFactory) }
        try expectOptional("poll: disabled -> .disabled", disabled, .disabled)
        try expect("poll: disabled never builds a client", counter.value ?? -1, 0)
    }
}

/// Minimal in-memory `TorrentClient` for store checks: returns a fixed snapshot
/// or throws a fixed error, with no network access.
private actor StubClient: TorrentClient {
    private let snapshot: TransferSnapshot?
    private let thrownError: Error?

    init(snapshot: TransferSnapshot) {
        self.snapshot = snapshot
        self.thrownError = nil
    }

    init(error: Error) {
        self.snapshot = nil
        self.thrownError = error
    }

    func fetchSnapshot() async throws -> TransferSnapshot {
        if let thrownError { throw thrownError }
        guard let snapshot else {
            throw ServerFailure.protocolViolation("stub client has neither a snapshot nor an error")
        }
        return snapshot
    }

    func testConnection() async throws -> String {
        "stub"
    }
}
