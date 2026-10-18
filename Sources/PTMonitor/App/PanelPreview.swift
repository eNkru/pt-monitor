import AppKit
import PTMonitorCore
import SwiftUI

/// `--preview-panel <out.png>`: renders the dropdown panel from fixture data,
/// in light and dark, and exits — a screenshot loop for the panel's visual work
/// without a live server or a hand-built `NSPanel`.
///
/// Debug-only: the menu bar agent path, `--selftest`, and `--probe` are
/// untouched, and nothing here touches the network or the Keychain (the stores
/// are built on a throwaway `UserDefaults` suite with a client factory that is
/// never called, since no poller is started).
///
/// `NSHostingView.cacheDisplay(in:to:)` rather than `ImageRenderer` (macOS 13+)
/// — the deployment target is macOS 12.
enum PanelPreview {

    /// Renders both variants; returns the process exit code.
    @MainActor
    static func run(arguments: [String]) -> Int32 {
        guard let output = outputURL(in: arguments) else {
            FileHandle.standardError.write(
                Data("preview-panel: expected an output path (--preview-panel <out.png>)\n".utf8)
            )
            return 1
        }

        // AppKit text drawing needs an application instance even though no run
        // loop is entered.
        _ = NSApplication.shared

        // Throwaway settings domain, dropped again once both renders are done.
        let settingsSuite = "com.ptmonitor.PTMonitor.preview.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: settingsSuite) }

        do {
            // `<out>` keeps the light render; the dark one gets `-dark` before the
            // extension (AC8). A path without an extension gets `.png`.
            let ext = output.pathExtension.isEmpty ? "png" : output.pathExtension
            let dark = URL(fileURLWithPath: "\(output.deletingPathExtension().path)-dark.\(ext)")
            try render(scheme: .light, to: output, settingsSuite: settingsSuite)
            try render(scheme: .dark, to: dark, settingsSuite: settingsSuite)
            print("preview-panel: wrote \(output.path)")
            print("preview-panel: wrote \(dark.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("preview-panel: \(error)\n".utf8))
            return 1
        }
    }

    private static func outputURL(in arguments: [String]) -> URL? {
        guard let flag = arguments.firstIndex(of: "--preview-panel"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        return URL(fileURLWithPath: arguments[arguments.index(after: flag)])
    }

    // MARK: - Rendering

    @MainActor
    private static func render(scheme: ColorScheme, to url: URL, settingsSuite: String) throws {
        let settings = fixtureSettings(suiteName: settingsSuite)
        let monitor = fixtureMonitor(settings: settings)

        let view = PanelView(settings: settings, monitor: monitor)
            .frame(width: PanelView.preferredWidth)
            .environment(\.colorScheme, scheme)

        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // Give the SwiftUI layout a first pass at a generous height, then
        // shrink to the content's real fitting size (the panel window does the
        // same via `PanelController`).
        hosting.frame = NSRect(x: 0, y: 0, width: PanelView.preferredWidth, height: 1_200)
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw PreviewError.cannotCreateBitmap
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw PreviewError.cannotEncodePNG
        }
        try data.write(to: url)
    }

    enum PreviewError: Error {
        case cannotCreateBitmap
        case cannotEncodePNG
    }

    // MARK: - Fixtures

    /// A throwaway `UserDefaults` suite, so a preview run cannot read or
    /// overwrite the user's real configuration (and leaves nothing behind).
    private static func fixtureSettings(suiteName: String) -> SettingsStore {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
        settings.replaceServers(servers)
        return settings
    }

    /// Fixture statuses injected directly — no poller is ever started, so the
    /// client factory (and therefore the Keychain) is never used.
    @MainActor
    private static func fixtureMonitor(settings: SettingsStore) -> MonitorStore {
        let monitor = MonitorStore(
            settings: settings,
            clientFactory: { _ in throw ServerFailure.unreachable("preview fixture never polls") }
        )
        monitor.setPreviewStatuses([
            servers[0].id: .online(homeSnapshot),
            servers[1].id: .online(seedboxSnapshot),
            servers[2].id: .failed(.auth("invalid username or password")),
        ])
        return monitor
    }

    private static let servers: [ServerConfig] = [
        ServerConfig(kind: .qbittorrent, name: "Home NAS", host: "192.168.1.2", port: 8080),
        ServerConfig(kind: .transmission, name: "Seedbox", host: "seed.example.net", port: 9091, useTLS: true),
        ServerConfig(kind: .qbittorrent, name: "Backups", host: "10.0.0.9", port: 8080),
    ]

    /// Every normalised `TorrentState`, plus the shapes the redesign targets: a
    /// name far too long for one line, a complete torrent, and zero-speed rows.
    private static let homeSnapshot = TransferSnapshot(
        downSpeed: 1_404_416,
        upSpeed: 419_430,
        activeTorrents: 4,
        totalTorrents: 9,
        freeSpace: 442_918_502_400,
        connectionState: .connected,
        torrents: [
            TorrentSummary(
                id: "1",
                // Long enough to still tail-truncate on line 2 (AC1).
                name: "[NoGroup] Ubuntu 24.04.1 Desktop amd64 (iso) — an intentionally very long release name that cannot possibly fit on two lines at 380pt panel width",
                state: .downloading, progress: 0.624, downSpeed: 1_258_291, upSpeed: 51_200, etaSeconds: 1_800
            ),
            TorrentSummary(
                id: "2", name: "Big Buck Bunny 2160p", state: .downloading,
                progress: 0.043, downSpeed: 146_201, upSpeed: 0, etaSeconds: nil
            ),
            TorrentSummary(
                id: "3", name: "Sintel.OpenMovie", state: .seeding,
                progress: 1, downSpeed: 0, upSpeed: 368_230, etaSeconds: nil
            ),
            TorrentSummary(
                id: "4", name: "debian-12.7.0-amd64-netinst", state: .seeding,
                progress: 1, downSpeed: 0, upSpeed: 0, etaSeconds: nil
            ),
            TorrentSummary(
                id: "5", name: "Movie.Collection.2024.1080p", state: .stalled,
                progress: 0.312, downSpeed: 0, upSpeed: 0, etaSeconds: nil
            ),
            TorrentSummary(
                id: "6", name: "queued-upcoming-release", state: .queued,
                progress: 0.9, downSpeed: 0, upSpeed: 0, etaSeconds: nil
            ),
            TorrentSummary(
                id: "7", name: "checking-in-progress", state: .checking,
                progress: 0.98, downSpeed: 0, upSpeed: 0, etaSeconds: nil
            ),
            TorrentSummary(
                id: "8", name: "paused-torrent", state: .paused,
                progress: 0.204, downSpeed: 0, upSpeed: 0, etaSeconds: nil
            ),
            TorrentSummary(
                id: "9", name: "broken-torrent", state: .error,
                progress: 0.11, downSpeed: 0, upSpeed: 0, etaSeconds: nil
            ),
        ]
    )

    private static let seedboxSnapshot = TransferSnapshot(
        downSpeed: 0,
        upSpeed: 2_097_152,
        activeTorrents: 2,
        totalTorrents: 2,
        freeSpace: 8_589_934_592,
        connectionState: .connected,
        torrents: [
            TorrentSummary(
                id: "a", name: "Private.Tracker.Release.Group", state: .seeding,
                progress: 1, downSpeed: 0, upSpeed: 2_097_152, etaSeconds: nil
            ),
            TorrentSummary(
                id: "b", name: "Small.Seed", state: .seeding,
                progress: 1, downSpeed: 0, upSpeed: 26_214, etaSeconds: nil
            ),
        ]
    )
}