import Foundation

// MARK: - Raw HTTP response

/// A status/header/body triple decoupled from `URLSession`, so the clients'
/// parsing and retry logic can be exercised without a live server (`--selftest`).
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    /// Header keys are lower-cased so lookup is case-insensitive.
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        var lowered: [String: String] = [:]
        for (key, value) in headers {
            lowered[key.lowercased()] = value
        }
        self.headers = lowered
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Body decoded as UTF-8 (qBittorrent returns plain text).
    public var text: String {
        String(decoding: body, as: UTF8.self)
    }
}

// MARK: - Endpoint parsing

/// Turns a user-typed host into a base URL.
///
/// Host interpretation is owned by `HostFieldParser` (so the client layer and
/// the preferences validation agree); this only adds the scheme/URL shape.
public enum EndpointParser {
    public static func baseURL(host rawHost: String, port configuredPort: Int, useTLS: Bool) throws -> URL {
        let parsed = try HostFieldParser.parse(rawHost, defaultPort: configuredPort)

        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = parsed.host
        components.port = parsed.port
        guard let url = components.url else {
            throw ServerFailure.unreachable("invalid host \"\(rawHost)\"")
        }
        return url
    }
}

// MARK: - Transport

/// Shared `URLSession` wrapper: timeouts, cookie handling, Basic auth, optional
/// self-signed TLS trust, and OS-error → `ServerFailure` mapping.
///
/// One instance per server. `TorrentClient` implementations are actors, so a
/// transport is only ever touched from its own client.
public final class HTTPTransport: @unchecked Sendable {
    public let baseURL: URL

    private let session: URLSession
    /// `URLSession` holds its delegate weakly, so the transport must retain it.
    private let transportDelegate: TransportSessionDelegate

    public init(config: ServerConfig, password: String?) throws {
        self.baseURL = try EndpointParser.baseURL(host: config.host, port: config.port, useTLS: config.useTLS)

        let password = password ?? ""
        let credentials: (username: String, password: String)? =
            (config.username.isEmpty && password.isEmpty) ? nil : (config.username, password)
        let delegate = TransportSessionDelegate(
            allowInsecureTLS: config.allowInsecureTLS,
            credentials: credentials
        )
        self.transportDelegate = delegate

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        // Private cookie storage: qBittorrent's `SID` cookie is scoped to this
        // server's session and never leaks to `HTTPCookieStorage.shared`.
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always

        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Builds an absolute URL under the base, e.g. `/api/v2/auth/login`.
    public func url(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url!
    }

    /// Sends a request and maps transport-level failures into
    /// `ServerFailure.unreachable`. HTTP status is returned verbatim — the
    /// clients own status interpretation.
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ServerFailure.protocolViolation("server returned a non-HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let text = value as? String {
                    headers[name] = text
                }
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let failure as ServerFailure {
            throw failure
        } catch let urlError as URLError {
            throw ServerFailure.unreachable(Self.describe(urlError))
        } catch {
            throw ServerFailure.unreachable(error.localizedDescription)
        }
    }

    /// Readable, cause-specific text for the common transport errors (AC8).
    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "host not found"
        case .cannotConnectToHost:
            return "connection refused"
        case .timedOut:
            return "timed out"
        case .networkConnectionLost:
            return "network connection lost"
        case .notConnectedToInternet:
            return "not connected to the network"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "TLS handshake failed (enable \"allow self-signed certificate\" if the server uses one)"
        case .cancelled:
            return "request cancelled"
        default:
            return error.localizedDescription
        }
    }
}

/// Answers TLS-trust and HTTP-auth challenges.
///
/// Both settings are immutable for the lifetime of the transport, so the class
/// is safe to hand to `URLSession` from any thread.
final class TransportSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowInsecureTLS: Bool
    private let credentials: (username: String, password: String)?

    init(allowInsecureTLS: Bool, credentials: (username: String, password: String)?) {
        self.allowInsecureTLS = allowInsecureTLS
        self.credentials = credentials
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            // Opt-in per server (design §4.3); default handling otherwise.
            guard allowInsecureTLS, let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))

        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            if let credentials, !(credentials.username.isEmpty && credentials.password.isEmpty) {
                let credential = URLCredential(
                    user: credentials.username,
                    password: credentials.password,
                    persistence: .forSession
                )
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Transmission session-id handshake

/// The `X-Transmission-Session-Id` handshake (research/apis.md §2.1).
///
/// On a `409` the server returns the correct id in a response header and the
/// client must resend the exact same request once. This applies to **every**
/// request, forever — the id rotates roughly hourly — and a `409` must never
/// reach the caller.
public enum SessionIdHandshake {
    public static let headerField = "X-Transmission-Session-Id"

    /// Pure retry decision, factored out so `--selftest` can assert on it
    /// without a live server.
    public struct Step: Equatable, Sendable {
        public let shouldRetry: Bool
        /// The session id to use next (the header value when present).
        public let sessionId: String?
    }

    /// The final response plus the session id that should be cached.
    public struct Outcome: Sendable {
        public let response: HTTPResponse
        public let sessionId: String?
    }

    /// Decides whether one response warrants a single retry. A second `409`
    /// (`hasRetried == true`) does not recurse.
    public static func step(statusCode: Int, sessionIdHeader: String?, hasRetried: Bool) -> Step {
        let header = sessionIdHeader.flatMap { $0.isEmpty ? nil : $0 }
        guard statusCode == 409, !hasRetried, let header else {
            return Step(shouldRetry: false, sessionId: header)
        }
        return Step(shouldRetry: true, sessionId: header)
    }

    /// Runs `perform` with the current session id; on a `409` stores the id from
    /// the response and retries exactly once. `perform` is injectable so the
    /// handshake is testable without a network.
    public static func run(
        initialSessionId: String?,
        perform: @Sendable (String?) async throws -> HTTPResponse
    ) async throws -> Outcome {
        var sessionId = initialSessionId
        var hasRetried = false
        while true {
            let response = try await perform(sessionId)
            let decision = step(
                statusCode: response.statusCode,
                sessionIdHeader: response.header(headerField),
                hasRetried: hasRetried
            )
            if decision.shouldRetry {
                sessionId = decision.sessionId
                hasRetried = true
                continue
            }
            return Outcome(response: response, sessionId: decision.sessionId ?? sessionId)
        }
    }
}
