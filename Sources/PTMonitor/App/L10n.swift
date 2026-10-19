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
    static var noActiveTorrents: String { s("No active torrents.") }
    static var connecting: String { s("Connecting…") }
    static var disabled: String { s("Disabled") }

    /// Row-cap footnote when a server exceeds
    /// `PanelView.maxVisibleTorrentsPerServer` rendered rows.
    static func moreTorrents(_ count: Int) -> String {
        String(format: s("%lld more torrents"), count)
    }

    // MARK: - Expanded torrent detail (R8)

    /// Text for one expanded-row detail line. `TorrentSummary.expandedLines`
    /// decides which lines exist and in what order; this only formats them.
    static func detailLine(_ line: TorrentDetailLine) -> String {
        switch line {
        case .size(let total, let downloaded, let progress):
            let size = ByteRateFormatter.bytes(total)
            if let downloaded {
                let percent = TorrentSummary.percentText(progress)
                return String(
                    format: s("Size %@ · %@ downloaded (%@)"),
                    size,
                    ByteRateFormatter.bytes(downloaded),
                    percent
                )
            }
            return String(format: s("Size %@"), size)

        case .ratio(let ratio, let uploaded, let downloaded):
            let formatted = String(format: "×%.2f", ratio)
            if let uploaded, let downloaded {
                return String(
                    format: s("Ratio %@ · %@ / %@"),
                    formatted,
                    ByteRateFormatter.bytes(uploaded),
                    ByteRateFormatter.bytes(downloaded)
                )
            }
            return String(format: s("Ratio %@"), formatted)

        case .peers(let seeders, let leechers):
            // Either count can be missing; the dashes are the honest rendering
            // of "the server did not report it".
            let seeds = seeders.map(String.init) ?? "—"
            let leech = leechers.map(String.init) ?? "—"
            return String(format: s("Seeds %@ · Leechers %@"), seeds, leech)

        case .trackerStatus(let status):
            let word = status == .working ? s("Working") : s("Not working")
            return String(format: s("Tracker %@"), word)

        case .category(let category):
            return String(format: s("Category %@"), category)

        case .error(let message):
            return String(format: s("Error %@"), message)
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
