import PTMonitorCore
import SwiftUI

/// Add/edit form for one server (R3, R7).
///
/// Validation and "Test Connection" are handled by `ServerEditorModel`; this
/// view is the thin rendering shell. The password written on save is only ever
/// handed to `KeychainStore` by `PreferencesView` — it never enters
/// `ServerConfig` (R4).
struct ServerEditorView: View {
    @StateObject private var model: ServerEditorModel
    let onSave: (ServerConfig, String) -> Void
    let onCancel: () -> Void

    init(
        existing: ServerConfig?,
        keychain: KeychainStore,
        onSave: @escaping (ServerConfig, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: ServerEditorModel(existing: existing, keychain: keychain))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isNew ? "Add Server" : "Edit Server")
                .font(.headline)

            Form {
                Picker("Type", selection: $model.kind) {
                    Text("qBittorrent").tag(ServerKind.qbittorrent)
                    Text("Transmission").tag(ServerKind.transmission)
                }
                TextField("Name", text: $model.name)
                TextField("Host", text: $model.host)
                TextField("Port", text: $model.port)
                Toggle("Use HTTPS", isOn: $model.useTLS)
                Toggle("Allow self-signed certificate", isOn: $model.allowInsecureTLS)
                TextField("User name", text: $model.username)
                SecureField("Password", text: $model.password)
                Toggle("Enabled", isOn: $model.isEnabled)
            }

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundColor(model.messageIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(model.isTesting ? "Testing…" : "Test Connection") { model.test() }
                    .disabled(model.isTesting)
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onChange(of: model.kind) { _ in model.kindChanged() }
    }

    private func save() {
        guard let validated = model.validated() else { return }
        onSave(validated.config, model.password)
    }
}

/// Editable state for one server, plus validation and Test Connection.
///
/// Not `@MainActor`: SwiftUI's `View` helpers are not main-actor isolated under
/// Swift 5.7, and the model is only ever read/written on the main thread.
/// `@unchecked Sendable` documents that (all async results are delivered back
/// through `MainActor.run`).
final class ServerEditorModel: ObservableObject, @unchecked Sendable {
    @Published var kind: ServerKind
    @Published var name: String
    @Published var host: String
    @Published var port: String
    @Published var useTLS: Bool
    @Published var allowInsecureTLS: Bool
    @Published var username: String
    @Published var password: String
    @Published var isEnabled: Bool

    /// Result of the last validation or Test Connection, shown under the form.
    @Published var message: String?
    @Published var messageIsError = false
    @Published var isTesting = false
    /// A non-fatal normalisation note (e.g. the port came from the host field).
    @Published var notice: String?

    let isNew: Bool
    private let id: UUID

    init(existing: ServerConfig?, keychain: KeychainStore) {
        self.isNew = existing == nil
        if let existing {
            self.id = existing.id
            self.kind = existing.kind
            self.name = existing.name
            self.host = existing.host
            self.port = String(existing.port)
            self.useTLS = existing.useTLS
            self.allowInsecureTLS = existing.allowInsecureTLS
            self.username = existing.username
            self.isEnabled = existing.isEnabled
            self.password = keychain.password(for: existing.id) ?? ""
        } else {
            self.id = UUID()
            self.kind = .qbittorrent
            self.name = ""
            self.host = ""
            self.port = String(ServerKind.qbittorrent.defaultPort)
            self.useTLS = false
            self.allowInsecureTLS = false
            self.username = ""
            self.isEnabled = true
            self.password = ""
        }
    }

    // MARK: - Editing

    /// Keeps the port in step with the type, but never clobbers a hand-typed one.
    func kindChanged() {
        let knownDefaults = [ServerKind.qbittorrent.defaultPort, ServerKind.transmission.defaultPort]
            .map(String.init)
        if port.isEmpty || knownDefaults.contains(port) {
            port = String(kind.defaultPort)
        }
    }

    // MARK: - Validation

    /// Normalises the form; on failure sets `message` and returns `nil`.
    func validated() -> ServerConfigValidator.Validated? {
        do {
            let result = try ServerConfigValidator.validate(draft())
            notice = result.notices.first
            message = nil
            messageIsError = false
            return result
        } catch let failure as ServerFailure {
            message = failure.message
            messageIsError = true
            return nil
        } catch {
            message = error.localizedDescription
            messageIsError = true
            return nil
        }
    }

    private func draft() -> ServerConfigDraft {
        ServerConfigDraft(
            id: id,
            kind: kind,
            name: name,
            host: host,
            port: port,
            useTLS: useTLS,
            allowInsecureTLS: allowInsecureTLS,
            username: username,
            isEnabled: isEnabled
        )
    }

    // MARK: - Test Connection (R7)

    func test() {
        message = nil
        notice = nil
        messageIsError = false
        isTesting = true

        guard let validated = validated() else {
            isTesting = false
            return
        }
        notice = validated.notices.first

        let config = validated.config
        let password = self.password
        Task { [weak self] in
            guard let model = self else { return }
            do {
                let client = try ServerEditorModel.makeClient(config: config, password: password)
                let version = try await client.testConnection()
                await MainActor.run {
                    model.message = "Connected: \(version)"
                    model.messageIsError = false
                    model.isTesting = false
                }
            } catch {
                let text = (error as? ServerFailure)?.message ?? error.localizedDescription
                await MainActor.run {
                    model.message = "Failed: \(text)"
                    model.messageIsError = true
                    model.isTesting = false
                }
            }
        }
    }

    private static func makeClient(config: ServerConfig, password: String) throws -> TorrentClient {
        switch config.kind {
        case .qbittorrent:
            return try QBittorrentClient(config: config, password: password)
        case .transmission:
            return try TransmissionClient(config: config, password: password)
        }
    }
}
