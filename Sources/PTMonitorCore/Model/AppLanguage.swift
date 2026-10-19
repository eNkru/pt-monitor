import Foundation

/// In-app language choice (R9 in-app switcher). Raw values are what
/// `SettingsStore` persists; `appleLanguages` is the per-app `AppleLanguages`
/// override that applies the choice at the next launch.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    /// No `AppleLanguages` override: macOS resolves the language per system
    /// preference (the bundle ships `en` + `zh-Hans`).
    case system
    case english = "en"
    case chinese = "zh-Hans"

    /// Label for the preferences picker. Only "Follow System" varies with the
    /// UI language; the language names stay native ("English", "简体中文") in
    /// both, matching how macOS itself lists languages.
    public var displayName: String {
        switch self {
        case .system:
            return NSLocalizedString("Follow System", comment: "language picker option")
        case .english:
            return "English"
        case .chinese:
            return "简体中文"
        }
    }

    /// `AppleLanguages` array this choice maps to; nil clears the override so
    /// the system-wide language order applies again.
    public var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .english: return ["en"]
        case .chinese: return ["zh-Hans"]
        }
    }
}
