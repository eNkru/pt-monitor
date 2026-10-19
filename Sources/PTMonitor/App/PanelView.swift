import SwiftUI
import PTMonitorCore

/// The entire dropdown as one SwiftUI view, rendered inside the CodexBar-style
/// floating panel (Q5, design §6.2).
///
/// Layout, top to bottom: header ("PT Monitor" + relative freshness + server
/// count), the aggregate number grid, per-server sections with torrent rows
/// (state dot, name, progress bar, detail line), and the footer action rows
/// (Refresh / Preferences / Quit). Everything except the footer is strictly
/// observational (R8, AC18).
///
/// Adaptive light/dark: the fixed dark-mode values from the CodexBar mockup map
/// onto semantic equivalents in light mode. Live numbers use monospaced digits
/// so rows do not jitter as speeds change.
struct PanelView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: MonitorStore

    /// Wired by `PanelController` after construction (two-phase init, so the
    /// closure can weakly capture the controller). Opens Preferences and
    /// dismisses the panel.
    var onPreferences: () -> Void = {}

    /// Called when the view's own content height changes (expanding or
    /// collapsing a torrent row). The controller re-fits the panel to the
    /// content; without this the window keeps its old height and the row list
    /// just grows a scrollbar until the next poll happens to relayout.
    var onContentHeightChange: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Constants (design §6.2)

    /// Panel width; the controller sizes the window from the content's
    /// fitting size at this width.
    static let preferredWidth: CGFloat = 380

    private static let cardRadius: CGFloat = 16
    private static let sectionScrollMaxHeight: CGFloat = 440

    /// Rows rendered per server before the "+ N more" footnote takes over.
    /// The clients' fixed sort puts downloading torrents first, so the cap
    /// drops only the long idle tail of a multi-thousand-torrent library —
    /// materialising all of it is what pinned the CPU at 60–99% with the
    /// dropdown closed. Plain text, no "show all" action (R8).
    static let maxVisibleTorrentsPerServer = 100

    /// Progress bar height. Thick enough to read at a glance (the old 4pt
    /// pill meter was near-invisible); the bar spans the whole row width.
    private static let progressBarHeight: CGFloat = 7

    /// Which torrent row is expanded in place (R7). At most one at a time:
    /// assigning a different id replaces the previous expansion. Pure view
    /// state — it performs no network call and mutates nothing on the server
    /// (the read-only contract permits view-state interactions only).
    @State private var expandedTorrentID: String?

    // MARK: - Body

    var body: some View {
        cardContent
            .padding(16)
            .frame(width: Self.preferredWidth)
            .background(cardBackground)
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            header
            if settings.servers.isEmpty {
                // First run: empty state plus an entry that opens Preferences
                // (AC4).
                emptyState
            } else {
                hairline
                    .padding(.top, 12)
                aggregateGrid
                    .padding(.top, 12)
                hairline
                    .padding(.top, 12)
                serverSections
            }
            footer
        }
    }

    // MARK: - Card chrome

    /// Near-opaque gradient fill behind the panel's blur; the mockup's dark
    /// values, with equivalent light neutrals for light mode.
    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .fill(cardGradient)
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var cardGradient: LinearGradient {
        if colorScheme == .dark {
            LinearGradient(
                colors: [
                    Color(red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x26 / 255.0),
                    Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            LinearGradient(
                colors: [Color(white: 0.99), Color(white: 0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Hairline border: ~8% white in dark mode, ~10% black in light mode.
    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.10)
    }

    private var hairlineColor: Color { borderColor }

    private var hairline: some View {
        Rectangle()
            .fill(hairlineColor)
            .frame(height: 0.5)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PT Monitor")
                    .font(.system(size: 15, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(L10n.freshness(fetched: newestFetchDate, now: timeline.date))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(serverCountText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    /// The newest snapshot across online servers; drives the freshness label.
    private var newestFetchDate: Date? {
        monitor.statuses.values.compactMap { $0.snapshot?.fetchedAt }.max()
    }

    /// "N servers · M online" via `L10n.serverCount` (localized).
    private var serverCountText: String {
        L10n.serverCount(total: settings.servers.count, online: monitor.aggregate.onlineServers)
    }

    // MARK: - Aggregate number grid (CodexBar's 2-column label-over-value grid)

    private var aggregateGrid: some View {
        let aggregate = monitor.aggregate
        let anyOnline = aggregate.onlineServers > 0
        let totalTorrents = monitor.statuses.values.reduce(0) { $0 + ($1.snapshot?.totalTorrents ?? 0) }
        // Free space is not meaningful to sum across servers, so the most
        // constrained reporting server is shown (same rule as the old menu).
        let freeSpace = monitor.statuses.values.compactMap { $0.snapshot?.freeSpace }.min()

        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            alignment: .leading,
            spacing: 12
        ) {
            stat(
                label: "↓ Speed",
                value: anyOnline ? "\(ByteRateFormatter.downArrow) \(ByteRateFormatter.rate(aggregate.downSpeed))" : "—"
            )
            stat(
                label: "↑ Speed",
                value: anyOnline ? "\(ByteRateFormatter.upArrow) \(ByteRateFormatter.rate(aggregate.upSpeed))" : "—"
            )
            stat(
                label: "Active Torrents",
                value: anyOnline ? L10n.activeTorrents(active: aggregate.activeTorrents, total: totalTorrents) : "—"
            )
            stat(
                label: "Free Space",
                value: freeSpace.map(ByteRateFormatter.bytes) ?? "—"
            )
        }
    }

    /// Labels go through `LocalizedStringKey` so the grid headers localize.
    private func stat(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Per-server sections

    private var enabledServers: [ServerConfig] {
        settings.servers.filter(\.isEnabled)
    }

    /// The whole mid-area scrolls when the sections are long; header, grid,
    /// and footer stay put. `LazyVStack` (not `VStack`): a plain `VStack`
    /// materialises every torrent row of every server up front — thousands of
    /// truncating texts and meters for a large library — while the lazy
    /// variant builds only what is visible.
    private var serverSections: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(enabledServers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 {
                        hairline
                            .padding(.bottom, 6)
                    }
                    section(server)
                }
            }
        }
        .frame(maxHeight: Self.sectionScrollMaxHeight)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func section(_ server: ServerConfig) -> some View {
        let status = monitor.statuses[server.id] ?? .connecting
        // Filter first, cap second: when "active only" is on, rows and the
        // "+ N more" footnote are both computed against the filtered array.
        // Clients already applied the fixed sort (design §6.1), and filtering
        // preserves that order; there is deliberately no user-facing sort UI.
        let library: [TorrentSummary]
        if case .online(let snapshot) = status {
            library = snapshot.torrents
        } else {
            library = []
        }
        let candidates = settings.showActiveTorrentsOnly ? library.filter(\.isActive) : library
        // Only the first `maxVisibleTorrentsPerServer` rows render; the rest
        // collapses into the footnote below (performance: see the constant).
        let visible = Array(candidates.prefix(Self.maxVisibleTorrentsPerServer))
        // The site decision belongs to the section, not the row: the header
        // shows it when every rendered row shares one site (R5), so it has to
        // be computed before the header is built — and from exactly the array
        // the row loop renders.
        let hoisted = TorrentSummary.hoistedSite(for: visible)

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(server, hoistedSite: hoisted)
            switch status {
            case .online:
                if candidates.isEmpty {
                    // Filter on + non-empty library + nothing transferring is
                    // its own state; an actually empty library stays "No
                    // torrents." either way.
                    note(settings.showActiveTorrentsOnly && !library.isEmpty
                        ? L10n.noActiveTorrents
                        : L10n.torrentsEmpty)
                } else {
                    // No hairline between rows: the rows' own vertical padding
                    // carries the rhythm, and a rule on every row was visual
                    // noise (design §separators).
                    ForEach(visible, id: \.id) { torrent in
                        row(torrent, hoistedSite: hoisted)
                    }
                    if candidates.count > visible.count {
                        note(L10n.moreTorrents(candidates.count - visible.count))
                    }
                }
            case .failed(let failure):
                // Cause-specific headline against the exact server (R6 /
                // AC7 / AC8), localized; the technical diagnostic detail stays
                // English beneath it.
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.causeHeadline(of: failure))
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Text(failure.message)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 6)
            case .connecting:
                note(L10n.connecting)
            case .disabled:
                // Unreachable: sections are filtered to enabled servers.
                // Kept so the switch is exhaustive.
                note(L10n.disabled)
            }
        }
    }

    /// Small-caps semibold secondary header: server display name plus its live
    /// speeds when online.
    private func sectionHeader(_ server: ServerConfig, hoistedSite: String?) -> some View {
        HStack(spacing: 8) {
            Text(server.displayName)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(.secondary)
            if case .online(let snapshot)? = monitor.statuses[server.id] {
                Text(ByteRateFormatter.speedText(down: snapshot.downSpeed, up: snapshot.upSpeed))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if let hoistedSite {
                Text(hoistedSite)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 3)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.bottom, 6)
    }

    // MARK: - Torrent rows

    /// One torrent, three layers (design §row):
    ///
    /// ```
    ///  ● Name wraps onto a second line when it helps        62.4%
    ///    ━━━━━━━━━━━━━━━━━━━━━━━━━━░░░░░░░░░░░░░  (7pt, full width)
    ///    ↓ 1.2M · 30m                      hdchina.org
    /// ```
    ///
    /// Which detail segments a row shows is decided by
    /// `TorrentSummary.infoSegments` (pure, `--selftest`-covered); this view
    /// only turns them into text. The PT site joins that same line, right
    /// aligned, so the collapsed row gains no height (R4/R9).
    ///
    /// A click expands the row in place (view state only — no network call, no
    /// server mutation, so the read-only contract still holds).
    private func row(_ torrent: TorrentSummary, hoistedSite: String?) -> some View {
        let expanded = expandedTorrentID == torrent.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: Self.layerSpacing) {
                Circle()
                    .fill(Self.color(for: torrent.state))
                    .frame(width: Self.dotSize, height: Self.dotSize)
                Text(torrent.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                progressBar(torrent.progress, color: Self.color(for: torrent.state))
                Text(TorrentSummary.percentText(torrent.progress))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Text(Self.infoText(torrent))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                // The site wins the width contest: `fixedSize` + a higher
                // layout priority make the info text truncate first, so the
                // site never disappears on a long row (R4). Suppressed when
                // the section header already shows it (R5).
                if let site = torrent.site, hoistedSite == nil {
                    Text(site)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            if expanded {
                expandedDetail(torrent)
            }
        }
        // All layers share the name's left edge (past the status dot),
        // so the row reads as one block.
        .padding(.leading, Self.dotSize + Self.layerSpacing)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            // One expansion at a time: tapping the open row closes it, tapping
            // another row moves the expansion there.
            expandedTorrentID = expanded ? nil : torrent.id
            onContentHeightChange()
        }
    }

    /// The expanded detail block (R8): one small secondary line per field the
    /// server actually reported. `TorrentSummary.expandedLines` decides which
    /// lines exist and in what order; this only renders their text.
    private func expandedDetail(_ torrent: TorrentSummary) -> some View {
        let lines = TorrentSummary.expandedLines(for: torrent)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(L10n.detailLine(line))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.top, 1)
    }

    /// Status dot diameter; also the name's baseline offset anchor.
    private static let dotSize: CGFloat = 6
    /// Gap between the status dot and the name.
    private static let layerSpacing: CGFloat = 6

    /// Full-row progress bar: a capsule track at 15% of the state colour with
    /// the fill scaled from the leading edge. Scaling instead of measuring
    /// keeps this layout-free (no `GeometryReader` in every row), and clipping
    /// to the capsule keeps the fill's ends as round as the track's.
    private func progressBar(_ progress: Double, color: Color) -> some View {
        Capsule()
            .fill(color.opacity(0.15))
            .frame(height: Self.progressBarHeight)
            .overlay {
                Capsule()
                    .fill(color)
                    .scaleEffect(x: TorrentSummary.clampedProgress(progress), anchor: .leading)
            }
            .clipShape(Capsule())
    }

    /// The row's detail line, e.g. `↓ 1.2M · 30m` or `Seeding`.
    private static func infoText(_ torrent: TorrentSummary) -> String {
        TorrentSummary.infoSegments(
            state: torrent.state,
            down: torrent.downSpeed,
            up: torrent.upSpeed,
            etaSeconds: torrent.etaSeconds
        )
        .map(text(for:))
        .joined(separator: " · ")
    }

    /// Localized text for one detail segment.
    private static func text(for segment: TorrentRowInfoSegment) -> String {
        switch segment {
        case .down(let rate): return "\(ByteRateFormatter.downArrow) \(ByteRateFormatter.rate(rate))"
        case .up(let rate): return "\(ByteRateFormatter.upArrow) \(ByteRateFormatter.rate(rate))"
        case .eta(let seconds): return L10n.eta(seconds)
        case .stateWord(let state): return L10n.stateWord(state)
        }
    }

    // MARK: - Presentation helpers

    /// Semantic colour per normalised state — the one presentation mapping the
    /// redesign kept verbatim; the dot and the progress bar both read from it.
    static func color(for state: TorrentState) -> Color {
        switch state {
        case .downloading: return .blue
        case .seeding: return .green
        case .stalled: return .orange
        case .error: return .red
        case .queued, .checking, .paused, .other: return .secondary
        }
    }

    // MARK: - Footer action rows

    private var footer: some View {
        VStack(spacing: 0) {
            hairline
                .padding(.bottom, 6)
            FooterRow(title: "Refresh Now", systemImage: "arrow.clockwise") {
                let monitor = self.monitor
                Task { await monitor.refreshNow() }
            }
            FooterRow(title: "Preferences…", systemImage: "gearshape") {
                onPreferences()
            }
            FooterRow(title: "Quit PT Monitor", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Empty state (AC4)

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No servers configured")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Button("Add Server…") { onPreferences() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

// MARK: -

/// Full-width footer row with a hover highlight. One of the panel's only
/// interactive elements — torrent rows and sections carry no actions (R8).
private struct FooterRow: View {
    /// LocalizedStringKey so the row titles resolve through Localizable.strings
    /// (a plain `String` would render verbatim).
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(.secondary)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}
