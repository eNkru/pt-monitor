import Foundation
import Security

/// Keychain-backed password storage (design §7, R4 / AC9).
///
/// Passwords **never** live in `UserDefaults`; each one is a
/// `kSecClassGenericPassword` item addressed by:
///
/// - `kSecAttrService` = `<bundle-id>.server`
/// - `kSecAttrAccount` = the server's `UUID`
///
/// The bundle identifier only exists inside the assembled `.app`; under
/// `swift run` (and in checks) there is none, so the service name falls back to
/// `fallbackService`. The type is a value type so it is trivially `Sendable`
/// and can be used from the main actor or from a polling task.
public struct KeychainStore: Sendable {
    /// Service used when no bundle identifier is available (`swift run`, checks).
    public static let fallbackService = "com.ptmonitor.PTMonitor.server"

    /// `<bundle-id>.server` inside the app bundle, else `fallbackService`.
    public static var defaultService: String {
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            return "\(bundleID).server"
        }
        return fallbackService
    }

    /// The service name every item owned by this store is scoped to.
    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    // MARK: - Reads

    /// Returns the stored password, or `nil` when there is none (including any
    /// Keychain error — a missing item and an unreadable item are equivalent
    /// for this app's purposes).
    public func password(for serverID: UUID) -> String? {
        var query = baseQuery(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Writes

    /// Stores `password` for `serverID`.
    ///
    /// An empty password means "clear it": the item is deleted rather than
    /// stored, so the Keychain never accumulates blank entries.
    /// - Returns: `true` when a password is now stored, `false` when it was
    ///   cleared. Throws `KeychainError` on an unexpected Keychain failure.
    @discardableResult
    public func setPassword(_ password: String, for serverID: UUID) throws -> Bool {
        guard !password.isEmpty else {
            try deletePassword(for: serverID)
            return false
        }

        let data = Data(password.utf8)
        let query = baseQuery(for: serverID)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus, operation: "add")
            }
            return true
        default:
            throw KeychainError(status: updateStatus, operation: "update")
        }
    }

    // MARK: - Deletes

    /// Deletes the password for `serverID`. Deleting a missing item is not an
    /// error, so a cleared or never-set password behaves identically.
    public func deletePassword(for serverID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    /// Deletes every password owned by this service, across all servers.
    /// Used when the whole configuration is reset.
    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete all")
        }
    }

    // MARK: - Query building

    private func baseQuery(for serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString
        ]
    }
}

/// A readable Keychain failure. `SecCopyErrorMessageString` supplies the OS
/// text, so the message is actionable rather than a bare `OSStatus`.
public struct KeychainError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    /// Which operation failed, e.g. `"add"`, `"update"`, `"delete"`.
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(detail)"
    }
}
