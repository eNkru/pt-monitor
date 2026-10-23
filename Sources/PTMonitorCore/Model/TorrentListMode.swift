import Foundation

/// Which slice of a server's torrent library the dropdown lists.
///
/// Display-only, like the old `showActiveTorrentsOnly` flag it replaces: the
/// mode filters rows the poll already fetched, so switching it never rebuilds
/// a poller or issues a request (R12).
///
/// The directional cases are defined by **live traffic**, not by state name:
/// a `.stalled` torrent with a trickle still counts as downloading, and a
/// seeding-but-also-downloading torrent appears in both directional lists.
/// `.active` is the union of the two directions — exactly
/// `TorrentSummary.isActive`.
public enum TorrentListMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// No filtering: the full library, in the client's fixed sort order.
    case all
    /// Torrents currently pulling data down.
    case downloading
    /// Torrents currently pushing data up.
    case uploading
    /// Torrents transferring in either direction.
    case active

    /// Whether `torrent` belongs in the list under this mode. Pure, so
    /// `--selftest` covers the whole truth table.
    public func matches(_ torrent: TorrentSummary) -> Bool {
        switch self {
        case .all: return true
        case .downloading: return torrent.downSpeed > 0
        case .uploading: return torrent.upSpeed > 0
        case .active: return torrent.isActive
        }
    }
}
