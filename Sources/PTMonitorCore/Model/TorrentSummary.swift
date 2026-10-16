import Foundation

/// Normalised per-torrent state (R12, design §6.1).
///
/// qBittorrent `state` strings and Transmission `status` integers both map onto
/// this; nothing above the client layer knows which API a server speaks.
public enum TorrentState: String, Codable, Equatable, Sendable {
    case downloading
    case seeding
    case stalled
    case queued
    case checking
    case paused
    case error
    case other
}

/// Normalised per-torrent summary (R12, design §3).
///
/// Produced by both clients alongside `TransferSnapshot.torrents`; consumed by
/// the dropdown's torrent list (design §6.2). Strictly observational (R8).
public struct TorrentSummary: Equatable, Sendable {
    /// qBittorrent torrent hash, or the Transmission torrent id as a string.
    public var id: String
    public var name: String
    public var state: TorrentState
    /// Download completion, always clamped into 0…1.
    public var progress: Double
    /// bytes/s
    public var downSpeed: Int64
    /// bytes/s
    public var upSpeed: Int64
    /// `nil` = unknown/infinite (the APIs' sentinel values).

    public var etaSeconds: Int64?

    public init(
        id: String,
        name: String,
        state: TorrentState,
        progress: Double,
        downSpeed: Int64 = 0,
        upSpeed: Int64 = 0,
        etaSeconds: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.progress = progress
        self.downSpeed = downSpeed
        self.upSpeed = upSpeed
        self.etaSeconds = etaSeconds
    }
}

extension TorrentSummary {
    /// Fixed sort order for the dropdown torrent list (design §6.1): downloading first,
    /// then seeding, then everything else; within each group by down speed
    /// (descending), then by name. Pure and static so `--selftest` can check
    /// it (AC17); there is deliberately no user-facing sort UI.
    public static func sorted(_ summaries: [TorrentSummary]) -> [TorrentSummary] {
        func rank(_ state: TorrentState) -> Int {
            switch state {
            case .downloading: return 0
            case .seeding: return 1
            case .stalled, .queued, .checking, .paused, .error, .other: return 2
            }
        }
        return summaries.sorted { lhs, rhs in
            let (lhsRank, rhsRank) = (rank(lhs.state), rank(rhs.state))
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.downSpeed != rhs.downSpeed { return lhs.downSpeed > rhs.downSpeed }
            return lhs.name < rhs.name
        }
    }

    /// Clamps a raw progress value into 0…1 at parse time (AC17). The APIs are
    /// documented as 0…1, but a malformed or missing field must never render a
    /// bar outside the 0…1 range (SwiftUI `ProgressView` traps on it).
    public static func clampedProgress(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }
}
