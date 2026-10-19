import CoreGraphics
import Foundation

/// How much room the menu bar speed text is allowed to take (design §6).
public enum MenuBarTextForm: Equatable, Sendable {
    /// `↓ 1.2M ↑ 340K`
    case full
    /// `↓1.2M ↑340K`
    case compact
}

/// Pure byte-rate formatting plus the menu bar width-degradation ladder.
///
/// This type is deliberately pure and AppKit-free so `--selftest` can assert on
/// it (AC14). The UI layer supplies the text-measurement closure; the ladder
/// itself holds no font or view state.
public enum ByteRateFormatter {

    public static let downArrow = "↓"
    public static let upArrow = "↑"

    private static let binaryStep = 1024.0
    private static let units = ["K", "M", "G", "T", "P", "E"]

    /// Formats a single rate.
    ///
    /// - `< 1024` bytes/s → `"999 B/s"` (integer bytes).
    /// - Otherwise scaled by 1024 with a `K`/`M`/`G`/… suffix.
    /// - One decimal below 100 (`"1.2M"`), zero decimals at 100 and above
    ///   (`"340K"`), so the string never grows unbounded.
    public static func rate(_ bytesPerSecond: Int64) -> String {
        let bytes = max(0, bytesPerSecond)
        if bytes < Int64(binaryStep) {
            return "\(bytes) B/s"
        }

        let (value, unitIndex) = scaled(bytes)
        let number: String
        if value < 100 {
            number = String(format: "%.1f", value)
        } else {
            number = String(format: "%.0f", value)
        }
        return number + units[unitIndex]
    }

    /// Formats a **byte count** (not a rate) for the free-space row, e.g.
    /// `412 GB`. Binary units, matching the rate formatter.
    public static func bytes(_ count: Int64) -> String {
        let bytes = max(0, count)
        if bytes < Int64(binaryStep) {
            return "\(bytes) B"
        }

        let (value, unitIndex) = scaled(bytes)
        let unit = units[unitIndex]
        if value < 10 {
            return String(format: "%.2f %@B", value, unit)
        }
        if value < 100 {
            return String(format: "%.1f %@B", value, unit)
        }
        return String(format: "%.0f %@B", value, unit)
    }

    /// Scales a byte count by 1024 into the largest fitting unit. Shared by
    /// `rate` and `bytes`, which differ only in their suffix and decimals.
    private static func scaled(_ bytes: Int64) -> (value: Double, unitIndex: Int) {
        var value = Double(bytes)
        var unitIndex = -1
        while value >= binaryStep && unitIndex < units.count - 1 {
            value /= binaryStep
            unitIndex += 1
        }
        return (value, unitIndex)
    }

    /// `↓ 1.2M ↑ 340K` (full) or `↓1.2M ↑340K` (compact).
    public static func speedText(down: Int64, up: Int64, form: MenuBarTextForm = .full) -> String {
        let gap = form == .full ? " " : ""
        return "\(downArrow)\(gap)\(rate(down)) \(upArrow)\(gap)\(rate(up))"
    }

    /// The degradation ladder: full form → compact form → `nil` (icon only).
    ///
    /// `measure` returns the rendered width of a candidate string. It is
    /// injected so this stays a pure function; the status item passes a
    /// `NSFont`-backed measurement, `--selftest` passes a synthetic one.
    /// Returns `nil` when even the compact form does not fit, and the string is
    /// never truncated mid-number (R5.2).
    public static func degradedSpeedText(
        down: Int64,
        up: Int64,
        availableWidth: CGFloat,
        measure: (String) -> CGFloat
    ) -> String? {
        let full = speedText(down: down, up: up, form: .full)
        if measure(full) <= availableWidth {
            return full
        }

        let compact = speedText(down: down, up: up, form: .compact)
        if measure(compact) <= availableWidth {
            return compact
        }

        return nil
    }
}
