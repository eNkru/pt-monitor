import AppKit
import Combine
import PTMonitorCore

/// Owns the single `NSStatusItem` (design §6).
///
/// The item shows a template SF Symbol that reflects the worst state among the
/// enabled servers, plus the aggregated speed text. The text is rendered with a
/// monospaced-digit font so it does not jitter, and degrades full → compact →
/// icon-only rather than being truncated mid-number (R5.2). It can be hidden by
/// preference with the icon still reflecting state (R5.3).
///
/// Clicking the item toggles the CodexBar-style floating panel
/// (`PanelController`, design §6.2). There is no `NSMenu`: a menu cannot render
/// the rounded card, and the panel keeps SwiftUI redrawing live while open.
@MainActor
final class StatusItemController: NSObject {

    /// Monospaced digits: `1` and `8` are the same width, so the status item
    /// does not twitch as speeds change.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    /// The menu bar exposes no "space left" API, so the app caps its own text
    /// footprint: a candidate wider than this is degraded by the formatter.
    /// Measured with the button's own font (above), so the ladder is honest.
    private static let maximumTextWidth: CGFloat = 110

    private let statusItem: NSStatusItem
    private let settings: SettingsStore
    private let monitor: MonitorStore
    private let panelController: PanelController

    private var cancellables = Set<AnyCancellable>()
    private var lastRenderKey: String?

    init(settings: SettingsStore, monitor: MonitorStore, onPreferences: @escaping () -> Void) {
        self.settings = settings
        self.monitor = monitor
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        guard let button = statusItem.button else {
            preconditionFailure("NSStatusBar returned a status item without a button")
        }
        self.panelController = PanelController(settings: settings, monitor: monitor, button: button, onPreferences: onPreferences)
        super.init()

        button.target = self
        button.action = #selector(togglePanel(_:))
        button.cell?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown

        observe()
        refresh()
    }

    // MARK: - Panel toggling

    @objc private func togglePanel(_ sender: Any?) {
        panelController.toggle()
    }

    // MARK: - Observation

    private func observe() {
        monitor.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

        // Settings changes cover the server list and the show-speeds toggle.
        settings.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Rendering

    private func refresh() {
        guard let button = statusItem.button else { return }

        let state = monitor.menuBarState
        let text = settings.showSpeedsInMenuBar ? currentSpeedText() : nil

        // Only touch AppKit when the rendered result actually changed.
        let key = "\(state)|\(text ?? "")"
        guard key != lastRenderKey else { return }
        lastRenderKey = key

        let image = NSImage(
            systemSymbolName: Self.iconName(for: state),
            accessibilityDescription: Self.accessibilityDescription(for: state)
        )
        image?.isTemplate = true // adapts to light/dark/highlighted menu bars
        button.image = image
        button.imagePosition = .imageLeft

        if let text {
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: Self.font])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    private func currentSpeedText() -> String? {
        let aggregate = monitor.aggregate
        return ByteRateFormatter.degradedSpeedText(
            down: aggregate.downSpeed,
            up: aggregate.upSpeed,
            availableWidth: Self.maximumTextWidth,
            measure: { text in
                (text as NSString).size(withAttributes: [.font: Self.font]).width
            }
        )
    }

    // MARK: - State mapping

    static func iconName(for state: MenuBarState) -> String {
        switch state {
        case .idle: return "arrow.down.circle"
        case .active: return "arrow.down.circle.fill"
        case .error: return "exclamationmark.triangle"
        }
    }

    static func accessibilityDescription(for state: MenuBarState) -> String {
        switch state {
        case .idle: return "PT Monitor idle"
        case .active: return "PT Monitor transferring"
        case .error: return "PT Monitor: all servers failing"
        }
    }
}
