import Foundation
import PTMonitorCore

/// Localization helpers for strings that are **built in code** (SwiftUI
/// `Text("literal")` views localize themselves through `LocalizedStringKey`
/// and `Localizable.strings`; these do not).
///
/// Keys are the English strings themselves, so any bundle without a matching
/// `.lproj` (e.g. `--probe` / `--selftest` running from the raw binary)
/// falls back to exactly the pre-localization English text. UI-facing only:
/// CLI output and the API clients' diagnostic detail stay English by design
/// (R9 revision, see `.trellis/spec/macos/app-conventions.md` §10).
enum L10n {

    private static func s(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    // MARK: - Panel header

    /// Relative freshness: "just now" under 5 s, then "Ns/m/h ago".
    static func freshness(fetched: Date?, now: Date) -> String {
        guard let fetched else { return "—" }
        let seconds = Int(now.timeIntervalSince(fetched))
        if seconds < 5 { return s("just now") }
        if seconds < 60 { return String(format: s("%llds ago"), seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: s("%lldm ago"), minutes) }
        return String(format: s("%lldh ago"), minutes / 60)
    }

    /// "N servers · M online" for the panel header; "Not configured" pre-setup.
    static func serverCount(total: Int, online: Int) -> String {
        guard total > 0 else { return s("Not configured") }
        let key = total == 1 ? "%lld server · %lld online" : "%lld servers · %lld online"
        return String(format: s(key), total, online)
    }

    // MARK: - Aggregate grid

    /// "3 · 7 total" under "Active Torrents" (active · total).
    static func activeTorrents(active: Int, total: Int) -> String {
        String(format: s("%lld · %lld total"), active, total)
    }

    // MARK: - Per-torrent rows

    /// The short state word a torrent row shows when it has no speed or eta to
    /// report. Localized so a zh-Hans user does not see an English word on an
    /// otherwise translated panel; the key is the English text (R9).
    static func stateWord(_ state: TorrentState) -> String {
        switch state {
        case .downloading: return s("Downloading")
        case .seeding: return s("Seeding")
        case .stalled: return s("Stalled")
        case .queued: return s("Queued")
        case .checking: return s("Checking")
        case .paused: return s("Paused")
        case .error: return s("Error")
        case .other: return s("Unknown")
        }
    }

    /// eta: `1h 23m` / `4m 05s` / `12s`; nil → an em dash (AC17).
    static func eta(_ seconds: Int64?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return String(format: s("%lldh %02lldm"), hours, minutes) }
        if minutes > 0 { return String(format: s("%lldm %02llds"), minutes, seconds % 60) }
        return String(format: s("%llds"), seconds)
    }

    // MARK: - Per-server sections

    static var torrentsEmpty: String { s("No torrents.") }

    /// Segmented list-filter labels. Kept short so four segments fit the fixed
    /// panel width; the arrows carry the direction without a sentence.
    static func listMode(_ mode: TorrentListMode) -> String {
        switch mode {
        case .all: return s("All")
        case .downloading: return s("↓ Down")
        case .uploading: return s("↑ Up")
        case .active: return s("Active")
        }
    }

    /// Shown instead of rows when the active filter matches nothing but the
    /// library is not empty.
    static func noTorrents(for mode: TorrentListMode) -> String {
        switch mode {
        case .all: return torrentsEmpty
        case .downloading: return s("No downloading torrents.")
        case .uploading: return s("No uploading torrents.")
        case .active: return s("No active torrents.")
        }
    }
    static var connecting: String { s("Connecting…") }
    static var disabled: String { s("Disabled") }

    /// Row-cap footnote when a server exceeds
    /// `PanelView.maxVisibleTorrentsPerServer` rendered rows.
    static func moreTorrents(_ count: Int) -> String {
        String(format: s("%lld more torrents"), count)
    }

    /// Tooltip of a row's web-UI button; `%@` is the server's display name.
    static func openInWebUI(_ serverName: String) -> String {
        String(format: s("Open %@ web UI"), serverName)
    }

    // MARK: - Expanded torrent detail (R8)

    /// The three parts of one expanded-row detail cell.
    /// `TorrentSummary.expandedLines` decides which cells exist and in what
    /// order; these only turn each one into a caption, a value, and an optional
    /// numeric note. Splitting them is what lets the view lay the detail out as
    /// a label-over-value grid instead of a run-on sentence — and it keeps the
    /// translatable part down to the short captions.

    /// Caption above the value, rendered in small caps by the view.
    static func detailLabel(_ line: TorrentDetailLine) -> String {
        switch line {
        case .size: return s("Size")
        case .ratio: return s("Ratio")
        case .peers: return s("Seeds / Leechers")
        case .trackerStatus: return s("Tracker")
        case .category: return s("Category")
        case .error: return s("Error")
        }
    }

    /// The cell's main value. Numbers are unit-formatted and monospaced by the
    /// view; only the words localize.
    static func detailValue(_ line: TorrentDetailLine) -> String {
        switch line {
        case .size(let total, _, _):
            return ByteRateFormatter.bytes(total)

        case .ratio(let ratio, _, _):
            return String(format: "×%.2f", ratio)

        case .peers(let seeders, let leechers):
            // Either count can be missing; the dashes are the honest rendering
            // of "the server did not report it".
            let seeds = seeders.map(String.init) ?? "—"
            let leech = leechers.map(String.init) ?? "—"
            return "\(seeds) / \(leech)"

        case .trackerStatus(let status):
            return status == .working ? s("Working") : s("Not working")

        case .category(let category):
            return category

        case .error(let message):
            return message
        }
    }

    /// Optional third line under the value: the numbers that used to be crammed
    /// into the same sentence. Both notes are arrows and units only — nothing to
    /// translate, and nothing repeated from the collapsed row (the completion
    /// percentage already sits at the progress bar's right end).
    static func detailNote(_ line: TorrentDetailLine) -> String? {
        switch line {
        case .size(_, let downloaded, _):
            // "how much of it has landed" — the total is the cell's value.
            guard let downloaded else { return nil }
            return "\(ByteRateFormatter.downArrow) \(ByteRateFormatter.bytes(downloaded))"

        case .ratio(_, let uploaded, let downloaded):
            guard let uploaded, let downloaded else { return nil }
            let up = ByteRateFormatter.bytes(uploaded)
            let down = ByteRateFormatter.bytes(downloaded)
            return "\(ByteRateFormatter.upArrow) \(up) · \(ByteRateFormatter.downArrow) \(down)"

        case .peers, .trackerStatus, .category, .error:
            return nil
        }
    }

    /// Cause-specific *headline* for a failed server (R6). The failure's own
    /// technical detail (`failure.message`, English) renders beneath this.
    static func causeHeadline(of failure: ServerFailure) -> String {
        switch failure {
        case .unreachable: return s("Unreachable")
        case .auth: return s("Sign-in failed")
        case .banned: return s("Temporarily banned")
        case .protocolViolation: return s("Unexpected response")
        case .serverError: return s("Server error")
        }
    }

    // MARK: - Editor (Test Connection)

    static func connected(_ version: String) -> String {
        String(format: s("Connected: %@"), version)
    }

    static func failed(_ detail: String) -> String {
        String(format: s("Failed: %@"), detail)
    }

    // MARK: - Preferences (server row / Keychain)

    /// Tooltip for the per-server enable/disable checkbox.
    static var enableDisableHelp: String { s("Enable or disable this server") }

    /// Keychain write failed while saving: nothing was persisted.
    static func keychainSaveFailure(_ error: String) -> String {
        String(format: s("Could not save the password to the Keychain (%@). Nothing was saved."), error)
    }

    // MARK: - Language switcher (R9 in-app revision)

    static var languageRestartNote: String {
        s("Changes take effect after PT Monitor restarts.")
    }

    static var relaunchNow: String { s("Relaunch Now") }

    // MARK: - Window

    static var preferencesTitle: String { s("PT Monitor Preferences") }
}
