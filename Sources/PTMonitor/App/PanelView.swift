import SwiftUI
import PTMonitorCore

/// The entire dropdown as one SwiftUI view, rendered inside the CodexBar-style
/// floating panel (Q5, design §6.2).
///
/// Layout, top to bottom: header ("PT Monitor" + relative freshness + server
/// count), the aggregate number grid, per-server sections with torrent rows and
/// pill progress meters, and the footer action rows (Refresh / Preferences /
/// Quit). Everything except the footer is strictly observational (R8, AC18).
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
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(server)
            switch monitor.statuses[server.id] ?? .connecting {
            case .online(let snapshot):
                // Filter first, cap second: when "active only" is on, rows and
                // the "+ N more" footnote are both computed against the
                // filtered array. Clients already applied the fixed sort
                // (design §6.1), and filtering preserves that order; there is
                // deliberately no user-facing sort UI (R8).
                let candidates = settings.showActiveTorrentsOnly
                    ? snapshot.torrents.filter(\.isActive)
                    : snapshot.torrents
                if candidates.isEmpty {
                    // Filter on + non-empty library + nothing transferring is
                    // its own state; an actually empty library stays "No
                    // torrents." either way.
                    note(settings.showActiveTorrentsOnly && !snapshot.torrents.isEmpty
                        ? L10n.noActiveTorrents
                        : L10n.torrentsEmpty)
                } else {
                    // Only the first `maxVisibleTorrentsPerServer` rows
                    // render; the rest collapses into the footnote below
                    // (performance: see the constant's comment).
                    let visible = candidates.prefix(Self.maxVisibleTorrentsPerServer)
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, torrent in
                        if index > 0 {
                            hairline
                                .padding(.leading, 14)
                        }
                        row(torrent)
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
    private func sectionHeader(_ server: ServerConfig) -> some View {
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
            Spacer(minLength: 0)
        }
        .padding(.bottom, 3)
    }

    private func note(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(isError ? .red : .secondary)
            .padding(.bottom, 6)
    }

    // MARK: - Torrent rows

    private func row(_ torrent: TorrentSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(for: torrent.state))
                    .foregroundColor(Self.color(for: torrent.state))
                    .frame(width: 14)
                Text(torrent.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Detail line under the name, aligned with it (icon 14pt + 8pt gap).
            HStack(spacing: 8) {
                PillMeter(progress: torrent.progress)
                Text(ByteRateFormatter.speedText(down: torrent.downSpeed, up: torrent.upSpeed))
                    .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 96, alignment: .trailing)
                Text(Self.etaText(torrent.etaSeconds))
                    .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.leading, 22)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Presentation helpers (pure; behaviour carried over verbatim
    // from the embedded list, so nothing observable changes)

    /// SF Symbol per normalised state. Only symbols available on macOS 12.
    static func symbol(for state: TorrentState) -> String {
        switch state {
        case .downloading: return "arrow.down.circle.fill"
        case .seeding: return "arrow.up.circle.fill"
        case .stalled: return "hourglass"
        case .queued: return "clock"
        case .checking: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .other: return "questionmark.circle"
        }
    }

    /// Semantic colour per normalised state.
    static func color(for state: TorrentState) -> Color {
        switch state {
        case .downloading: return .blue
        case .seeding: return .green
        case .stalled: return .orange
        case .queued, .checking: return .secondary
        case .paused: return .secondary
        case .error: return .red
        case .other: return .secondary
        }
    }

    /// `nil` eta renders as an em dash, never a bogus number (AC17).
    /// Localized unit formats; English falls back via the key.
    static func etaText(_ seconds: Int64?) -> String {
        L10n.eta(seconds)
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

/// Pill-shaped progress meter (CodexBar's usage-meter shape): capsule track at
/// ~10% fill opacity, capsule fill in the teal accent.
private struct PillMeter: View {
    /// Teal accent from the CodexBar mockup.
    private static let accent = Color(red: 0x4F / 255.0, green: 0xB6 / 255.0, blue: 0xC3 / 255.0)

    private static let trackWidth: CGFloat = 90
    private static let meterHeight: CGFloat = 4

    /// 0…1; clamped so a bogus server value cannot blow up the layout.
    let progress: Double

    var body: some View {
        let fraction = min(max(progress, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Self.accent.opacity(0.10))
            Capsule()
                .fill(Self.accent)
                .frame(width: Self.trackWidth * fraction)
        }
        .frame(width: Self.trackWidth, height: Self.meterHeight)
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
