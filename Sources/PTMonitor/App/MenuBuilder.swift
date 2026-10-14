import AppKit
import Combine
import PTMonitorCore

/// Builds the dropdown menu each time it is opened (design §6).
///
/// This is the menu's target, so the Refresh/Preferences/Quit items can call
/// back without retaining a separate action object. The menu is informational:
/// it is read-only (R8), so server rows carry no actions.
@MainActor
final class MenuBuilder: NSObject {

    private let settings: SettingsStore
    private let monitor: MonitorStore
    private let onPreferences: () -> Void

    init(settings: SettingsStore, monitor: MonitorStore, onPreferences: @escaping () -> Void) {
        self.settings = settings
        self.monitor = monitor
        self.onPreferences = onPreferences
        super.init()
    }

    /// Replaces the menu's contents with the current state. Called from
    /// `menuNeedsUpdate(_:)`, so the dropdown is always fresh.
    func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let servers = settings.servers
        if servers.isEmpty {
            // First run: empty state plus an entry that opens Preferences (AC4).
            menu.addItem(informational("No servers configured"))
            menu.addItem(actionItem("Add Server…", #selector(openPreferences(_:))))
        } else {
            menu.addItem(informational(headerText()))
            menu.addItem(.separator())

            for server in servers {
                menu.addItem(serverItem(for: server))
            }
            if let freeSpace = freeSpaceText() {
                menu.addItem(informational("Free space: \(freeSpace)"))
            }

            menu.addItem(.separator())
            menu.addItem(actionItem("Refresh Now", #selector(refreshNow(_:)), key: "r"))
            menu.addItem(actionItem("Preferences…", #selector(openPreferences(_:)), key: ","))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Quit PT Monitor", #selector(quit(_:)), key: "q"))
    }

    // MARK: - Rows

    /// `↓ 2.4M ↑ 680K · 7 active`, aggregated over every enabled server (AC10).
    private func headerText() -> String {
        let aggregate = MonitorStore.aggregate(monitor.statuses)
        guard aggregate.onlineServers > 0 else {
            return "No servers online"
        }
        let speed = ByteRateFormatter.speedText(down: aggregate.downSpeed, up: aggregate.upSpeed)
        return "\(speed) · \(aggregate.activeTorrents) active"
    }

    private func serverItem(for server: ServerConfig) -> NSMenuItem {
        let status = monitor.statuses[server.id] ?? (server.isEnabled ? .connecting : .disabled)

        let detail: String
        let isError: Bool
        switch status {
        case .online(let snapshot):
            let speed = ByteRateFormatter.speedText(down: snapshot.downSpeed, up: snapshot.upSpeed)
            detail = "\(speed) · \(snapshot.activeTorrents) active"
            isError = false
        case .failed(let failure):
            // The cause-specific hint is the row's title (R6 / AC7 / AC8).
            detail = failure.message
            isError = true
        case .connecting:
            detail = "connecting…"
            isError = false
        case .disabled:
            detail = "disabled"
            isError = false
        }

        let item = NSMenuItem()
        item.attributedTitle = rowTitle(name: server.displayName, detail: detail, isError: isError)
        item.isEnabled = true // informational; no action, but keep normal contrast
        return item
    }

    /// Free space is not meaningful to sum across servers, so the most
    /// constrained reporting server is shown.
    private func freeSpaceText() -> String? {
        let values = monitor.statuses.values.compactMap { $0.snapshot?.freeSpace }
        guard let smallest = values.min() else { return nil }
        return ByteRateFormatter.bytes(smallest)
    }

    // MARK: - Item construction

    private func informational(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )
        item.isEnabled = false
        return item
    }

    private func rowTitle(name: String, detail: String, isError: Bool) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.foregroundColor: NSColor.labelColor, .font: font]
        )
        title.append(NSAttributedString(
            string: "  \(detail)",
            attributes: [
                .foregroundColor: isError ? NSColor.systemRed : NSColor.secondaryLabelColor,
                .font: font
            ]
        ))
        return title
    }

    private func actionItem(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: - Actions

    @objc private func refreshNow(_ sender: Any?) {
        let monitor = self.monitor
        Task { await monitor.refreshNow() }
    }

    @objc private func openPreferences(_ sender: Any?) {
        onPreferences()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
