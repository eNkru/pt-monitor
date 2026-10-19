import AppKit
import PTMonitorCore

/// Owns the app's long-lived objects and wires the stores to the UI (design §2).
///
/// The app is a menu bar agent: `.accessory` activation policy, so there is no
/// Dock icon and no window at launch (R1). The only UI is the status item and
/// the preferences window, which is created lazily but not shown.
///
/// All of this is main-actor isolated: AppKit and the observable stores are
/// only ever touched from the main thread.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = SettingsStore()
    private let keychain = KeychainStore()

    private var monitor: MonitorStore!
    private var preferences: PreferencesWindowController!
    private var statusItem: StatusItemController!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: main.swift already set this before `run()`.
        NSApp.setActivationPolicy(.accessory)

        let monitor = MonitorStore(settings: settings, keychain: keychain)
        let preferences = PreferencesWindowController(settings: settings, keychain: keychain, monitor: monitor)
        let statusItem = StatusItemController(
            settings: settings,
            monitor: monitor,
            onPreferences: { [weak preferences] in preferences?.show() }
        )

        self.monitor = monitor
        self.preferences = preferences
        self.statusItem = statusItem

        Task { await monitor.reconcile() }
    }

    /// Fired by "Quit PT Monitor" (⌘Q) and by logout/shutdown. Polling tasks are
    /// cancelled; the process then exits (AC15).
    func applicationWillTerminate(_ notification: Notification) {
        let monitor = self.monitor
        Task { await monitor?.stop() }
    }

    /// The agent has no main window; closing the preferences window must not
    /// terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
