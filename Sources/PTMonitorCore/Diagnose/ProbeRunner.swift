import Foundation

/// Headless single-server probe (R11 / AC13, design §9).
///
/// `PTMonitor --probe <type> --host <h> --port <p> [--user u] [--pass p]
/// [--https] [--insecure]` fetches one snapshot with the matching client,
/// prints it as JSON to stdout, and exits 0. On failure it prints a readable
/// message to stderr and exits non-zero. It never touches AppKit, so it can be
/// run from the assembled `.app` binary without launching the GUI.
///
/// This lives in `PTMonitorCore` because the executable calls it; it is
/// deliberately UI-free.
public enum ProbeRunner {

    // MARK: - Options

    /// Parsed `--probe` flags.
    public struct Options: Equatable, Sendable {
        public var kind: ServerKind
        public var host: String
        public var port: Int
        public var username: String
        public var password: String
        public var useTLS: Bool
        public var allowInsecureTLS: Bool

        public init(
            kind: ServerKind,
            host: String,
            port: Int,
            username: String = "",
            password: String = "",
            useTLS: Bool = false,
            allowInsecureTLS: Bool = false
        ) {
            self.kind = kind
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.useTLS = useTLS
            self.allowInsecureTLS = allowInsecureTLS
        }
    }

    /// A usage problem, distinct from a server failure so it can exit 2.
    public struct UsageError: Error, CustomStringConvertible, Equatable {
        public let detail: String
        public init(_ detail: String) { self.detail = detail }
        public var description: String { detail }
    }

    public static let usage = """
    Usage: PTMonitor --probe <qbittorrent|transmission> --host <host> [options]

      --probe <type>     Server type: qbittorrent or transmission (required)
      --host <host>      Host name, IP address, or URL (required)
      --port <port>      Server port (default: 8080 / 9091 per type)
      --user <username>  User name
      --pass <password>  Password
      --https            Use HTTPS
      --insecure         Allow a self-signed certificate

    Prints the fetched snapshot as JSON on success.
    """

    // MARK: - Entry point

    /// Runs the probe and returns the process exit code (0 success, 1 server
    /// failure, 2 usage error). Output is written to stdout/stderr directly.
    public static func run(arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            write(usage + "\n", to: .standardOutput)
            return 0
        }

        let options: Options
        do {
            options = try parse(arguments)
        } catch let error as UsageError {
            write("probe: \(error.detail)\n\(usage)\n", to: .standardError)
            return 2
        } catch {
            write("probe: \(error.localizedDescription)\n", to: .standardError)
            return 2
        }

        let config = ServerConfig(
            kind: options.kind,
            name: options.kind.displayName,
            host: options.host,
            port: options.port,
            useTLS: options.useTLS,
            allowInsecureTLS: options.allowInsecureTLS,
            username: options.username,
            isEnabled: true
        )

        do {
            let client: TorrentClient
            switch options.kind {
            case .qbittorrent:
                client = try QBittorrentClient(config: config, password: options.password)
            case .transmission:
                client = try TransmissionClient(config: config, password: options.password)
            }
            let snapshot = try await client.fetchSnapshot()
            let json = try encode(snapshot: snapshot, config: config)
            write(String(decoding: json, as: UTF8.self) + "\n", to: .standardOutput)
            return 0
        } catch let failure as ServerFailure {
            write("probe: \(failure.kindLabel): \(failure.message)\n", to: .standardError)
            return 1
        } catch {
            write("probe: \(error.localizedDescription)\n", to: .standardError)
            return 1
        }
    }

    // MARK: - Argument parsing

    /// Parses the probe flags, allowing them in any order. `--probe` takes the
    /// server type as its value.
    public static func parse(_ arguments: [String]) throws -> Options {
        var kind: ServerKind?
        var host: String?
        var port: Int?
        var username = ""
        var password = ""
        var useTLS = false
        var allowInsecureTLS = false

        var index = 0
        func nextValue(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw UsageError("\(flag) requires a value")
            }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--probe":
                let raw = try nextValue("--probe")
                guard let parsed = ServerKind(rawValue: raw.lowercased()) else {
                    throw UsageError("unknown server type \"\(raw)\" (expected qbittorrent or transmission)")
                }
                kind = parsed
            case "--host":
                host = try nextValue("--host")
            case "--port":
                let raw = try nextValue("--port")
                guard let parsed = Int(raw), (1...65535).contains(parsed) else {
                    throw UsageError("invalid port \"\(raw)\" (expected 1-65535)")
                }
                port = parsed
            case "--user":
                username = try nextValue("--user")
            case "--pass":
                password = try nextValue("--pass")
            case "--https":
                useTLS = true
            case "--insecure":
                allowInsecureTLS = true
            default:
                throw UsageError("unexpected argument \"\(argument)\"")
            }
            index += 1
        }

        guard let kind else {
            throw UsageError("missing --probe <qbittorrent|transmission>")
        }
        guard let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageError("missing --host <host>")
        }

        return Options(
            kind: kind,
            host: host,
            port: port ?? kind.defaultPort,
            username: username,
            password: password,
            useTLS: useTLS,
            allowInsecureTLS: allowInsecureTLS
        )
    }

    // MARK: - JSON output

    /// Encodes the snapshot (plus the server it came from) as pretty JSON.
    ///
    /// Kept separate and pure so `--selftest` can assert on the shape.
    public static func encode(snapshot: TransferSnapshot, config: ServerConfig) throws -> Data {
        let snapshotObject: [String: Any] = [
            "downSpeed": snapshot.downSpeed,
            "upSpeed": snapshot.upSpeed,
            "activeTorrents": snapshot.activeTorrents,
            "totalTorrents": snapshot.totalTorrents,
            "freeSpace": snapshot.freeSpace.map { $0 as Any } ?? NSNull(),
            "connectionState": snapshot.connectionState.rawValue,
            "fetchedAt": ISO8601DateFormatter().string(from: snapshot.fetchedAt)
        ]
        let serverObject: [String: Any] = [
            "kind": config.kind.rawValue,
            "name": config.displayName,
            "host": config.host,
            "port": config.port,
            "tls": config.useTLS
        ]
        let root: [String: Any] = ["server": serverObject, "snapshot": snapshotObject]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Output helper

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data(text.utf8))
    }
}
