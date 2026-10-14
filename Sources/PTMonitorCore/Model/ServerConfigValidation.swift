import Foundation

// MARK: - Host field parsing

/// The `(host, port)` pair a user's host field actually denotes.
///
/// The host field is deliberately forgiving (design §4.3): a pasted
/// `http://nas:8080/` is parsed rather than sent verbatim, `host:port` splits,
/// and non-HTTP schemes (`ws://`) are rejected with a readable message.
public struct ParsedHostField: Equatable, Sendable {
    /// Host only, no scheme, port, path, or userinfo.
    public var host: String
    /// Port, either explicit in the field or the supplied default.
    public var port: Int
    /// `true`/`false` when the field carried a scheme; `nil` when it did not.
    public var schemeIsTLS: Bool?
    /// Whether a port was taken from the field itself.
    public var extractedPort: Bool

    public init(host: String, port: Int, schemeIsTLS: Bool?, extractedPort: Bool) {
        self.host = host
        self.port = port
        self.schemeIsTLS = schemeIsTLS
        self.extractedPort = extractedPort
    }
}

/// Single owner for turning a typed host into `(host, port)`.
///
/// `EndpointParser` (client layer) and `ServerConfigValidator` (preferences)
/// both use this, so a host is interpreted the same way everywhere.
public enum HostFieldParser {
    public static func parse(_ rawHost: String, defaultPort: Int) throws -> ParsedHostField {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw ServerFailure.unreachable("no host configured")
        }

        // Strip a scheme if one was pasted. Only http(s) make sense here.
        var schemeIsTLS: Bool?
        if let schemeSeparator = host.range(of: "://") {
            let scheme = host[host.startIndex..<schemeSeparator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else {
                throw ServerFailure.unreachable("unsupported URL scheme \"\(scheme)://\" — enter a plain host name or IP address")
            }
            schemeIsTLS = (scheme == "https")
            host = String(host[schemeSeparator.upperBound...])
        }
        // Drop any path, then any pasted userinfo.
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }

        var port = defaultPort
        var extractedPort = false
        if host.hasPrefix("[") {
            // IPv6 literal, e.g. [2001:db8::1]:8080
            guard let close = host.firstIndex(of: "]") else {
                throw ServerFailure.unreachable("malformed IPv6 host \"\(rawHost)\"")
            }
            let address = String(host[host.index(after: host.startIndex)..<close])
            let remainder = host[host.index(after: close)...]
            if remainder.hasPrefix(":") {
                guard let explicit = Int(remainder.dropFirst()) else {
                    throw ServerFailure.unreachable("invalid port in \"\(rawHost)\"")
                }
                port = explicit
                extractedPort = true
            }
            host = address
        } else if let colon = host.lastIndex(of: ":"), !host[host.startIndex..<colon].contains(":") {
            // Exactly one colon: host:port.
            guard let explicit = Int(host[host.index(after: colon)...]) else {
                throw ServerFailure.unreachable("invalid port in \"\(rawHost)\"")
            }
            port = explicit
            extractedPort = true
            host = String(host[..<colon])
        }

        guard !host.isEmpty else {
            throw ServerFailure.unreachable("invalid host \"\(rawHost)\"")
        }
        guard (1...65535).contains(port) else {
            throw ServerFailure.unreachable("invalid port \(port)")
        }

        return ParsedHostField(
            host: host,
            port: port,
            schemeIsTLS: schemeIsTLS,
            extractedPort: extractedPort
        )
    }
}

// MARK: - Preferences validation

/// Raw, user-typed server fields before they are turned into a `ServerConfig`.
///
/// `port` is a `String` because the preferences UI accepts free typing; it is
/// validated here rather than in the view.
public struct ServerConfigDraft: Equatable, Sendable {
    public var id: UUID
    public var kind: ServerKind
    public var name: String
    public var host: String
    public var port: String
    public var useTLS: Bool
    public var allowInsecureTLS: Bool
    public var username: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: ServerKind,
        name: String = "",
        host: String = "",
        port: String = "",
        useTLS: Bool = false,
        allowInsecureTLS: Bool = false,
        username: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.allowInsecureTLS = allowInsecureTLS
        self.username = username
        self.isEnabled = isEnabled
    }
}

/// Validates and normalises a `ServerConfigDraft` before it is saved (R3, R7).
public enum ServerConfigValidator {
    /// A normalised config plus any adjustments the user should be told about.
    public struct Validated: Equatable, Sendable {
        public var config: ServerConfig
        public var notices: [String]
        public init(config: ServerConfig, notices: [String]) {
            self.config = config
            self.notices = notices
        }
    }

    /// - Throws: `ServerFailure.unreachable` with a readable message when a
    ///   field is invalid. The preferences UI shows `message` verbatim.
    public static func validate(_ draft: ServerConfigDraft) throws -> Validated {
        var notices: [String] = []

        let rawHost = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawHost.isEmpty else {
            throw ServerFailure.unreachable("enter a host name or IP address")
        }

        let portText = draft.port.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPort: Int
        if portText.isEmpty {
            fallbackPort = draft.kind.defaultPort
        } else {
            guard let value = Int(portText), (1...65535).contains(value) else {
                throw ServerFailure.unreachable("port must be a whole number between 1 and 65535")
            }
            fallbackPort = value
        }

        let parsed = try HostFieldParser.parse(rawHost, defaultPort: fallbackPort)
        if parsed.extractedPort && !portText.isEmpty {
            notices.append("Used port \(parsed.port) from the host field.")
        }

        var useTLS = draft.useTLS
        if let schemeIsTLS = parsed.schemeIsTLS {
            if schemeIsTLS != useTLS {
                notices.append(
                    schemeIsTLS
                        ? "Enabled HTTPS because the host starts with https://."
                        : "Disabled HTTPS because the host starts with http://."
                )
            }
            useTLS = schemeIsTLS
        }

        let config = ServerConfig(
            id: draft.id,
            kind: draft.kind,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: parsed.host,
            port: parsed.port,
            useTLS: useTLS,
            allowInsecureTLS: draft.allowInsecureTLS,
            username: draft.username.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: draft.isEnabled
        )
        return Validated(config: config, notices: notices)
    }
}
