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

/// One piece of a torrent row's detail line (design §row, layer 3).
///
/// The *decision* of which segments a row shows lives here as a pure value with
/// no strings, so `--selftest` can assert it; the app target turns each segment
/// into localized text. Never carries a zero rate — a `↓`/`↑` arrow for 0 B/s
/// was the visual noise the redesign removed.
public enum TorrentRowInfoSegment: Equatable, Sendable {
    /// Download rate, bytes/s.
    case down(Int64)
    /// Upload rate, bytes/s.
    case up(Int64)
    /// Remaining time, seconds (already free of the APIs' sentinels).
    case eta(Int64)
    /// Nothing else applies — render the localized word for this state.
    case stateWord(TorrentState)
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

    /// Whether this torrent currently transfers data in either direction.
    /// Pure so `--selftest` can check it; drives the "active only" list filter.
    public var isActive: Bool { downSpeed > 0 || upSpeed > 0 }

    /// The detail line under a torrent row's name (design §row, layer 3).
    ///
    /// Only what the state actually means: a transferring torrent shows the
    /// rate(s) moving plus — while downloading — the eta; every other state a
    /// single word. Both directions are shown whenever both are moving: a
    /// torrent can seed while it downloads, and dropping its upload rate would
    /// hide real traffic. Zero rates are omitted rather than rendered as an
    /// arrow with no number, and a row that would otherwise be empty falls
    /// back to its state word — never a bare em dash.
    public static func infoSegments(
        state: TorrentState,
        down: Int64,
        up: Int64,
        etaSeconds: Int64?
    ) -> [TorrentRowInfoSegment] {
        var segments: [TorrentRowInfoSegment] = []
        switch state {
        case .downloading:
            if down > 0 { segments.append(.down(down)) }
            if up > 0 { segments.append(.up(up)) }
            // A negative eta is a "unknown" sentinel that slipped through; it
            // would stringify to an em dash, which is exactly the noise being
            // removed, so it is dropped like a missing one.
            if let etaSeconds, etaSeconds >= 0 { segments.append(.eta(etaSeconds)) }
        case .seeding:
            if up > 0 { segments.append(.up(up)) }
        case .stalled, .queued, .checking, .paused, .error, .other:
            break
        }
        if segments.isEmpty {
            segments.append(.stateWord(state))
        }
        return segments
    }

    /// `"62%"` for the progress bar's right end. Pure and language-neutral
    /// (both supported languages write it the same way), so it lives here
    /// rather than in the view and is covered by `--selftest`.
    public static func percentText(_ progress: Double) -> String {
        "\(Int((clampedProgress(progress) * 100).rounded()))%"
    }
}
