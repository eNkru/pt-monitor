import Foundation

/// Normalised connection state, mapped from qBittorrent's `connection_status`
/// string and from Transmission's implicit "RPC answered" state.
public enum ConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case firewalled
    case disconnected
    case unknown
}

/// One cross-client snapshot of a server's transfer state.
///
/// Both `QBittorrentClient` and `TransmissionClient` produce this; nothing above
/// the client layer knows which API the server speaks.
public struct TransferSnapshot: Equatable, Sendable {
    /// Global download rate, bytes/s.
    public var downSpeed: Int64
    /// Global upload rate, bytes/s.
    public var upSpeed: Int64
    public var activeTorrents: Int
    public var totalTorrents: Int
    /// Free space on the server's default download path; `nil` when the server
    /// cannot report it (qBittorrent < WebAPI 2.1.1, or a failed Transmission
    /// `free-space` call).
    public var freeSpace: Int64?
    public var connectionState: ConnectionState
    public var fetchedAt: Date
    /// Per-torrent summaries for the dropdown torrent list (R12, design §6.2).
    /// Empty when the server reports no torrents or the client could not list
    /// them.
    public var torrents: [TorrentSummary]

    public init(
        downSpeed: Int64 = 0,
        upSpeed: Int64 = 0,
        activeTorrents: Int = 0,
        totalTorrents: Int = 0,
        freeSpace: Int64? = nil,
        connectionState: ConnectionState = .unknown,
        fetchedAt: Date = Date(),
        torrents: [TorrentSummary] = []
    ) {
        self.downSpeed = downSpeed
        self.upSpeed = upSpeed
        self.activeTorrents = activeTorrents
        self.totalTorrents = totalTorrents
        self.freeSpace = freeSpace
        self.connectionState = connectionState
        self.fetchedAt = fetchedAt
        self.torrents = torrents
    }
}
