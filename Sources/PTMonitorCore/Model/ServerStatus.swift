import Foundation

/// Cause-specific failure, so the dropdown can show an actionable hint against
/// the exact server that failed (R6 / AC7 / AC8).
public enum ServerFailure: Equatable, Sendable {
    /// DNS failure, connection refused, timeout, or TLS trust rejection.
    case unreachable(String)
    /// Credentials rejected by the server.
    case auth(String)
    /// Reachable, answered HTTP, but the payload did not match the API.
    case protocolViolation(String)
    /// The server itself refused: Transmission 403/421, qBittorrent banned IP.
    case serverError(String)

    /// The human-readable detail carried by the case.
    public var message: String {
        switch self {
        case .unreachable(let message),
             .auth(let message),
             .protocolViolation(let message),
             .serverError(let message):
            return message
        }
    }

    /// Short label for the menu row, e.g. "auth failed".
    public var kindLabel: String {
        switch self {
        case .unreachable: return "unreachable"
        case .auth: return "auth failed"
        case .protocolViolation: return "unexpected response"
        case .serverError: return "server error"
        }
    }

    /// True when the failure is credential-related (used to avoid retry storms).
    public var isCredentialFailure: Bool {
        if case .auth = self { return true }
        return false
    }
}

/// Live state of one configured server.
public enum ServerStatus: Equatable, Sendable {
    /// Configured but disabled: never contacted (AC12).
    case disabled
    /// A poll is in flight and no snapshot has been produced yet.
    case connecting
    case online(TransferSnapshot)
    case failed(ServerFailure)

    public var snapshot: TransferSnapshot? {
        if case .online(let snapshot) = self { return snapshot }
        return nil
    }

    public var failure: ServerFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}
