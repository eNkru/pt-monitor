import AppKit
import Combine
import PTMonitorCore
import SwiftUI

/// Owns the CodexBar-style floating panel that replaces the `NSMenu` dropdown
/// (Q5, design §6.2).
///
/// The panel is a borderless, non-activating `NSPanel` anchored under the
/// status item. Rounded corners, the hairline border, and the gradient live in
/// the SwiftUI content (`PanelView`); the window itself is clear so the system
/// shadow follows the card's shape. Showing the panel never activates the app,
/// so keyboard focus stays wherever it was (AC18).
///
/// Dismissal: a global monitor closes on clicks in other apps, a local monitor
/// closes on clicks elsewhere in this app, Esc closes via a local key monitor
/// (plus `cancelOperation` as a fallback path), and re-clicking the status item
/// toggles. Clicks *inside* the panel never dismiss it (AC18).
@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private static let edgeGap: CGFloat = 8

    private let panel: NSPanel
    private let hostingView: NSHostingView<PanelView>
    private let button: NSStatusBarButton

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore, monitor: MonitorStore, button: NSStatusBarButton, onPreferences: @escaping () -> Void) {
        self.button = button
        let view = PanelView(settings: settings, monitor: monitor)
        self.hostingView = NSHostingView(rootView: view)
        self.panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelView.preferredWidth, height: 360),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        // Two-phase wiring: `self` cannot be captured before every stored
        // property is initialized, so the dismiss-aware Preferences action is
        // installed here. Weak self — the hosting view outlives nothing here,
        // but the closure must not keep the controller alive.
        hostingView.rootView.onPreferences = { [weak self] in
            self?.hide()
            onPreferences()
        }

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        // The app is `.accessory`; it may never be the active application, so
        // "hide on deactivate" must stay off.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = hostingView
        hostingView.autoresizingMask = [.width, .height]

        // The panel is a real window, so SwiftUI redraws on every publish
        // while it is open (design §6.2). Store changes can change the content
        // height (server added/removed), so both stores trigger a relayout.
        monitor.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.relayoutIfVisible() } }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.relayoutIfVisible() } }
            .store(in: &cancellables)
    }

    deinit {
        // Belt and braces: `hide()` always removes the monitors, and they use
        // `weak self` so the handlers are inert either way. The controller is
        // app-lifetime in practice (owned by the status item controller).
        MainActor.assumeIsolated {
            removeMonitors()
        }
    }

    // MARK: - Show / hide

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        layout()
        installMonitors()
        panel.orderFrontRegardless() // never activates the app
        panel.makeKey() // receive Esc through the local key monitor; still no activation
    }

    func hide() {
        panel.orderOut(nil)
        removeMonitors()
    }

    // MARK: - Layout

    /// Sizes the panel to its SwiftUI content (fixed width, content-driven
    /// height capped at 70% of the screen) and centers it under the status
    /// item, flipping above the item if it would run off the screen bottom
    /// (design §6.2).
    private func layout() {
        guard let screen = button.window?.screen ?? NSScreen.main else { return }
        guard let itemFrame = statusItemScreenFrame() else { return }

        hostingView.frame.size.width = PanelView.preferredWidth
        let fitting = hostingView.fittingSize
        let maxHeight = screen.visibleFrame.height * 0.7
        let size = NSSize(width: PanelView.preferredWidth, height: min(max(fitting.height, 120), maxHeight))
        hostingView.setFrameSize(size)

        let visible = screen.visibleFrame
        var origin = NSPoint(
            x: itemFrame.midX - size.width / 2,
            y: itemFrame.minY - Self.edgeGap - size.height // just below the item
        )
        if origin.y < visible.minY {
            // Would run off the bottom of the screen: flip above the item.
            origin.y = itemFrame.maxY + Self.edgeGap
        }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Re-anchors the panel under the item when its content height changes
    /// while visible (torrents arriving, server sections appearing).
    private func relayoutIfVisible() {
        guard panel.isVisible else { return }
        layout()
    }

    private func statusItemScreenFrame() -> NSRect? {
        guard let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: - Dismissal monitors

    private func installMonitors() {
        removeMonitors()

        // Clicks in *other* apps: any click outside the panel closes it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.hide()
                }
            }
        }

        // Clicks in *our* app: close unless the click is inside the panel or
        // on the status item itself. The status item is excluded because its
        // own action toggles the panel — a monitor-triggered close there
        // would be immediately undone by the toggle.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                let click = NSEvent.mouseLocation
                let insidePanel = self.panel.frame.contains(click)
                let onStatusItem = self.statusItemScreenFrame()?.contains(click) ?? false
                if !insidePanel && !onStatusItem {
                    self.hide()
                }
            }
            // Pass the event through either way: the click belongs to the
            // window it landed on (e.g. the Preferences window).
            return event
        }

        // Esc. Key events only reach this app when it is frontmost (the panel
        // never activates the app), so this is best-effort; `cancelOperation`
        // on the panel subclass is the second path.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel.isVisible, isEscape else { return false }
                self.hide()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    /// Called by the panel subclass when an Esc key event falls through the
    /// responder chain unhandled (`cancelOperation`).
    func panelDidRequestDismissal() {
        hide()
    }
}

/// The borderless, non-activating panel. `canBecomeKey` must be true so the
/// panel can receive key events (for Esc) without activating the app.
private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if let controller = delegate as? PanelController {
            controller.panelDidRequestDismissal()
        } else {
            super.cancelOperation(sender)
        }
    }
}
