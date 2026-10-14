import AppKit
import PTMonitorCore
import SwiftUI

/// Hosts the SwiftUI preferences UI in an `NSWindow` (design §2, §9).
///
/// Deployment target is macOS 12, which has no SwiftUI `Settings` scene, so the
/// window and its controller are built by hand. The window is created once and
/// reused; closing it does not terminate the agent.
@MainActor
final class PreferencesWindowController: NSWindowController {

    init(settings: SettingsStore, keychain: KeychainStore, monitor: MonitorStore) {
        let rootView = PreferencesView(
            settings: settings,
            keychain: keychain,
            onChange: { [weak monitor] in
                // Add/edit/delete/enable and interval changes all rebuild the
                // pollers (a changed Keychain password is invisible to config).
                Task { @MainActor in await monitor?.reconcile() }
            }
        )
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "PT Monitor Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 460))
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Brings the preferences window to the front. An `.accessory` app is not
    /// active by default, so it must be activated explicitly.
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
