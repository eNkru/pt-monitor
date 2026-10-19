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

    // MARK: - Detail fields (expanded row)
    //
    // Every one of these is optional and `nil` means **the server did not report
    // it** — never zero. Both APIs ship them in the response the poll already
    // fetches, so reading them costs no extra request.

    /// Torrent size in bytes (`total_size` / `totalSize`).
    public var totalSize: Int64?
    /// Bytes downloaded so far.
    public var downloaded: Int64?
    /// Bytes uploaded so far.
    public var uploaded: Int64?
    /// Share ratio; the APIs' `-1` "not available" sentinel is normalised to `nil`.
    public var ratio: Double?
    /// Connected seeders.
    public var seeders: Int?
    /// Connected leechers.
    public var leechers: Int?
    /// PT site derived from the first announce URL (see `site(fromAnnounceURL:)`).
    public var site: String?
    /// State of the first tracker in the announce list, when the API reports one.
    public var trackerStatus: TrackerStatus?
    /// qBittorrent category; an empty string is normalised to `nil`.
    public var category: String?
    /// The client's own failure text (Transmission `errorString`).
    public var errorMessage: String?

    public init(
        id: String,
        name: String,
        state: TorrentState,
        progress: Double,
        downSpeed: Int64 = 0,
        upSpeed: Int64 = 0,
        etaSeconds: Int64? = nil,
        totalSize: Int64? = nil,
        downloaded: Int64? = nil,
        uploaded: Int64? = nil,
        ratio: Double? = nil,
        seeders: Int? = nil,
        leechers: Int? = nil,
        site: String? = nil,
        trackerStatus: TrackerStatus? = nil,
        category: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.progress = progress
        self.downSpeed = downSpeed
        self.upSpeed = upSpeed
        self.etaSeconds = etaSeconds
        self.totalSize = totalSize
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.ratio = ratio
        self.seeders = seeders
        self.leechers = leechers
        self.site = site
        self.trackerStatus = trackerStatus
        self.category = category
        self.errorMessage = errorMessage
    }
}

/// State of a torrent's first tracker, normalised from the API's numeric status.
///
/// String-free on purpose: the app target renders the localized word, so
/// `--selftest` can assert the decision without touching `L10n`.
public enum TrackerStatus: Equatable, Sendable {
    case working
    case notWorking
}

/// One line of a torrent row's expanded detail block, in display order.
///
/// Like `TorrentRowInfoSegment`, this is a *decision* with no strings, so
/// `--selftest` can assert which lines a torrent produces; `L10n` turns each
/// case into text.
public enum TorrentDetailLine: Equatable, Sendable {
    case size(total: Int64, downloaded: Int64?, progress: Double)
    case ratio(ratio: Double, uploaded: Int64?, downloaded: Int64?)
    case peers(seeders: Int?, leechers: Int?)
    case trackerStatus(TrackerStatus)
    case category(String)
    case error(String)
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

    // MARK: - PT site (R1–R3)

    /// The PT site a torrent came from, derived from its first announce URL.
    ///
    /// Deliberately naive: strip the scheme, the port, the path/query, and a
    /// leading `tracker.` / `announce.` / `t.` / `tr.` / `www.` label. There is
    /// no public-suffix list and no friendly-name table — a hand-maintained
    /// domain map rots the moment a new site is joined, and registrable-domain
    /// reduction needs a PSL. `tracker.hdchina.org` → `hdchina.org`.
    ///
    /// `nil` (or a blank string) yields `nil`: a torrent with no announce URL
    /// shows no site rather than a placeholder.
    public static func site(fromAnnounceURL url: String?) -> String? {
        guard var host = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else { return nil }

        // Scheme: `https://`, `http://`, `udp://`, `wss://`, … — anything before
        // the first `://` is not part of the host.
        if let range = host.range(of: "://") {
            host = String(host[range.upperBound...])
        }

        // Cut at the first path separator, query, fragment, or port.
        let terminators: Set<Character> = ["/", "?", "#", ":"]
        if let index = host.firstIndex(where: { terminators.contains($0) }) {
            host = String(host[..<index])
        }

        host = host.lowercased()

        // Strip known announce-host prefixes, at most twice: `tracker.announce.x`
        // is unlikely but `t.tracker.x` happens.
        let prefixes = ["tracker.", "announce.", "www.", "tr.", "t."]
        var stripped = 0
        while stripped < 2, let prefix = prefixes.first(where: { host.hasPrefix($0) }) {
            host = String(host.dropFirst(prefix.count))
            stripped += 1
        }

        return host.isEmpty ? nil : host
    }

    /// The site shared by **every** row in a section, or `nil` when the site must
    /// be shown per row.
    ///
    /// Hoisting the site to the section header keeps a dedicated single-site PT
    /// box from repeating `hdchina.org` on a hundred rows. Mixed sites — or any
    /// row with no site at all — fall back to per-row, because a header would
    /// then claim a site that some rows are not from.
    public static func hoistedSite(for torrents: [TorrentSummary]) -> String? {
        guard let first = torrents.first?.site else { return nil }
        for torrent in torrents where torrent.site != first { return nil }
        return first
    }

    // MARK: - Expanded row (R7–R8)

    /// Which lines the expanded detail block shows, in display order.
    ///
    /// A field the server did not report is simply omitted — never rendered as
    /// a zero or a dash, which would be indistinguishable from a real `0 B`.
    public static func expandedLines(for torrent: TorrentSummary) -> [TorrentDetailLine] {
        var lines: [TorrentDetailLine] = []
        if let total = torrent.totalSize {
            lines.append(.size(total: total, downloaded: torrent.downloaded, progress: torrent.progress))
        }
        if let ratio = torrent.ratio {
            lines.append(.ratio(ratio: ratio, uploaded: torrent.uploaded, downloaded: torrent.downloaded))
        }
        if torrent.seeders != nil || torrent.leechers != nil {
            lines.append(.peers(seeders: torrent.seeders, leechers: torrent.leechers))
        }
        if let status = torrent.trackerStatus {
            lines.append(.trackerStatus(status))
        }
        if let category = torrent.category {
            lines.append(.category(category))
        }
        if let error = torrent.errorMessage {
            lines.append(.error(error))
        }
        return lines
    }
}
