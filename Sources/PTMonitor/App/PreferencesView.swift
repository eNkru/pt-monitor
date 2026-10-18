import PTMonitorCore
import SwiftUI

/// The preferences form: server list, poll interval, and the menu bar toggle
/// (R3, R5.3). Add/edit happens in a `ServerEditorView` sheet.
struct PreferencesView: View {
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainStore
    /// Called after any change that should rebuild the pollers.
    let onChange: () -> Void

    @State private var editorTarget: EditorTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Servers")
                .font(.headline)

            if settings.servers.isEmpty {
                Text("No servers configured. Add a qBittorrent or Transmission server to start monitoring.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                List {
                    ForEach(settings.servers) { server in
                        ServerRow(
                            server: server,
                            onToggle: { isEnabled in
                                settings.setEnabled(isEnabled, for: server.id)
                                onChange()
                            },
                            onEdit: { editorTarget = .edit(server) },
                            onDelete: { delete(server) }
                        )
                    }
                }
                .frame(minHeight: 160)
            }

            HStack {
                Button("Add Server…") { editorTarget = .add }
                Spacer()
            }

            Divider()

            Stepper(value: pollIntervalBinding, in: SettingsStore.pollIntervalRange, step: 1) {
                Text("Poll every \(Int(settings.pollInterval)) seconds")
            }

            Toggle("Show speeds in the menu bar", isOn: showSpeedsBinding)

            Toggle("Show active torrents only", isOn: showActiveTorrentsOnlyBinding)

            Divider()

            LanguageSection(settings: settings)

            Spacer()
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 460, alignment: .topLeading)
        .sheet(item: $editorTarget) { target in
            ServerEditorView(
                existing: target.config,
                keychain: keychain,
                onSave: { config, password in
                    let error = save(config: config, password: password, isNew: target.config == nil)
                    if error == nil {
                        editorTarget = nil
                    }
                    return error
                },
                onCancel: { editorTarget = nil }
            )
        }
    }

    // MARK: - Actions

    /// Writes the password to the Keychain **before** the configuration, so a
    /// failed Keychain write cannot leave an enabled server that polls with an
    /// empty password (which trips qBittorrent's IP ban after a few attempts).
    ///
    /// - Returns: an error message to show in the editor, or `nil` on success.
    private func save(config: ServerConfig, password: String, isNew: Bool) -> String? {
        do {
            // The password lives only in the Keychain, never in ServerConfig (R4).
            try keychain.setPassword(password, for: config.id)
        } catch {
            return L10n.keychainSaveFailure("\(error)")
        }
        if isNew {
            settings.add(config)
        } else {
            settings.update(config)
        }
        onChange()
        return nil
    }

    private func delete(_ server: ServerConfig) {
        settings.delete(id: server.id)
        try? keychain.deletePassword(for: server.id)
        onChange()
    }

    // MARK: - Bindings

    private var pollIntervalBinding: Binding<Double> {
        Binding(
            get: { settings.pollInterval },
            set: { newValue in
                settings.setPollInterval(newValue)
                onChange()
            }
        )
    }

    private var showSpeedsBinding: Binding<Bool> {
        Binding(
            get: { settings.showSpeedsInMenuBar },
            set: { settings.setShowSpeedsInMenuBar($0) }
        )
    }

    /// Display-only: mirrors `showSpeedsBinding` and deliberately does not call
    /// `onChange()` — filtering the list never rebuilds the pollers.
    private var showActiveTorrentsOnlyBinding: Binding<Bool> {
        Binding(
            get: { settings.showActiveTorrentsOnly },
            set: { settings.setShowActiveTorrentsOnly($0) }
        )
    }
}

/// Language switcher (R9 in-app revision): Follow System / English / 简体中文.
/// The choice is persisted via `SettingsStore.setAppLanguage`, which also
/// writes the per-app `AppleLanguages` override. That key is read only at
/// launch, so a note says a restart is needed and offers a relaunch button.
private struct LanguageSection: View {
    @ObservedObject var settings: SettingsStore
    @State private var confirmRelaunch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Language", selection: languageBinding) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220, alignment: .leading)

            HStack(spacing: 8) {
                Text(L10n.languageRestartNote)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if settings.appLanguage != .system {
                    Button(L10n.relaunchNow) { Relauncher.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settings.appLanguage },
            set: { settings.setAppLanguage($0) }
        )
    }
}

/// Relaunches the app so a language change takes effect.
@MainActor
enum Relauncher {
    /// Launches the .app bundle again and terminates. When running the raw
    /// SwiftPM binary there is no bundle to `open`; re-exec the binary itself.
    static func relaunch() {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "app" {
            NSWorkspace.shared.open(bundle.bundleURL)
        } else {
            let executable = CommandLine.arguments[0]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(CommandLine.arguments.dropFirst())
            try? process.run()
        }
        NSApp.terminate(nil)
    }
}

/// Which server the editor sheet is open for.
private enum EditorTarget: Identifiable {
    case add
    case edit(ServerConfig)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let server): return server.id.uuidString
        }
    }

    var config: ServerConfig? {
        switch self {
        case .add: return nil
        case .edit(let server): return server
        }
    }
}

/// One row of the server list: enable toggle, identity, and edit/delete.
private struct ServerRow: View {
    let server: ServerConfig
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { server.isEnabled }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(L10n.enableDisableHelp)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                Text("\(server.kind.displayName) · \(endpoint)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Edit") { onEdit() }
            Button("Delete") { onDelete() }
        }
        .padding(.vertical, 2)
    }

    private var endpoint: String {
        "\(server.useTLS ? "https" : "http")://\(server.endpointDescription)"
    }
}
