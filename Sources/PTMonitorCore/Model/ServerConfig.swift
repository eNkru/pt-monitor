import Foundation

/// Which remote API a server speaks. Both are normalised into one domain model
/// (`TransferSnapshot`), so nothing above the client layer branches on this
/// except client selection and editor defaults.
public enum ServerKind: String, Codable, CaseIterable, Sendable {
    case qbittorrent
    case transmission

    /// Human-readable name used as the default display name.
    public var displayName: String {
        switch self {
        case .qbittorrent: return "qBittorrent"
        case .transmission: return "Transmission"
        }
    }

    /// Default WebUI/RPC port (qBittorrent 8080, Transmission 9091).
    public var defaultPort: Int {
        switch self {
        case .qbittorrent: return 8080
        case .transmission: return 9091
        }
    }
}

/// One server entry, exactly as persisted in `UserDefaults` by `SettingsStore`.
///
/// The password is intentionally **not** part of this type: it lives in the
/// Keychain, keyed by `id` (see `KeychainStore`). This keeps the preferences
/// plist free of credentials (R4 / AC9).
public struct ServerConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ServerKind
    /// Display name. Defaults to `kind.displayName`.
    public var name: String
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var allowInsecureTLS: Bool
    public var username: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: ServerKind,
        name: String? = nil,
        host: String = "",
        port: Int? = nil,
        useTLS: Bool = false,
        allowInsecureTLS: Bool = false,
        username: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.host = host
        self.port = port ?? kind.defaultPort
        self.useTLS = useTLS
        self.allowInsecureTLS = allowInsecureTLS
        self.username = username
        self.isEnabled = isEnabled
    }

    /// Name to show in the menu; never empty.
    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.displayName : name
    }

    /// `host:port` label for diagnostics and error rows.
    public var endpointDescription: String {
        "\(host):\(port)"
    }

    /// URL of this server's own web UI, for opening it in the browser.
    ///
    /// Built from this config's own `host`/`port`/`useTLS` through
    /// `EndpointParser.baseURL`, so the URL agrees with what the client would
    /// talk to (same `HostFieldParser`). Throws when the host is unusable.
    ///
    /// Neither upstream web UI supports selecting a torrent by URL —
    /// qBittorrent only understands `#download=<url>`, Transmission only
    /// `?addtorrent=` — so neither fragment nor query is appended and the UI's
    /// own state decides what is shown.
    ///
    /// The kind branch lives here rather than in the view so no caller has to
    /// switch on `ServerKind` (app-conventions §3). `/transmission/web/` mirrors
    /// the hardcoded `/transmission/rpc` RPC path in `TransmissionClient`.
    public func webUIURL() throws -> URL {
        let base = try EndpointParser.baseURL(host: host, port: port, useTLS: useTLS)
        guard kind == .transmission else { return base }
        return base.appendingPathComponent("transmission/web/")
    }
}
