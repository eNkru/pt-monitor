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

/// Validates and normalises a `ServerConfig` before it is saved (R3, R7).
///
/// `portText` is the preferences UI's free-typed port field, validated here
/// rather than in the view. The passed config's `port` is only a placeholder —
/// the field wins whenever it parses.
public enum ServerConfigValidator {
    /// A normalised config plus the one adjustment the user should be told about.
    public struct Validated: Equatable, Sendable {
        public var config: ServerConfig
        public var notice: String?
        public init(config: ServerConfig, notice: String?) {
            self.config = config
            self.notice = notice
        }
    }

    /// - Throws: `ServerFailure.unreachable` with a readable message when a
    ///   field is invalid. The preferences UI shows `message` verbatim.
    public static func validate(_ config: ServerConfig, portText: String) throws -> Validated {
        let rawHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawHost.isEmpty else {
            throw ServerFailure.unreachable(NSLocalizedString("enter a host name or IP address", comment: "validation"))
        }

        let portText = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPort: Int
        if portText.isEmpty {
            fallbackPort = config.kind.defaultPort
        } else {
            guard let value = Int(portText), (1...65535).contains(value) else {
                throw ServerFailure.unreachable(
                    NSLocalizedString("port must be a whole number between 1 and 65535", comment: "validation"))
            }
            fallbackPort = value
        }

        let parsed = try HostFieldParser.parse(rawHost, defaultPort: fallbackPort)
        // Only one notice is ever shown; the port adjustment keeps precedence,
        // as it did when these were collected into an array and `.first` read.
        var notice: String?
        if parsed.extractedPort && !portText.isEmpty {
            notice = String(
                format: NSLocalizedString("Used port %lld from the host field.", comment: "validation notice"),
                parsed.port)
        }

        var useTLS = config.useTLS
        if let schemeIsTLS = parsed.schemeIsTLS {
            if schemeIsTLS != useTLS, notice == nil {
                notice = schemeIsTLS
                    ? NSLocalizedString("Enabled HTTPS because the host starts with https://.", comment: "notice")
                    : NSLocalizedString("Disabled HTTPS because the host starts with http://.", comment: "notice")
            }
            useTLS = schemeIsTLS
        }

        return Validated(
            config: ServerConfig(
                id: config.id,
                kind: config.kind,
                name: config.name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: parsed.host,
                port: parsed.port,
                useTLS: useTLS,
                allowInsecureTLS: config.allowInsecureTLS,
                username: config.username.trimmingCharacters(in: .whitespacesAndNewlines),
                isEnabled: config.isEnabled
            ),
            notice: notice
        )
    }
}
