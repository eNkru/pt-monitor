# Design — Torrent List Redesign

## Scope

Presentation-only redesign of the per-torrent rows inside
`Sources/PTMonitor/App/PanelView.swift`, plus a new debug-only
`--preview-panel` argv mode for screenshot iteration. No model, client,
store, polling, or panel-window changes.

## New row anatomy

Replaces `row(_:)` and the private `PillMeter` in `PanelView.swift`.

```
 ● Long torrent name wraps onto a second line when it helps, tail-truncate
   at line 2                                                    62.4%
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━░░░░░░░░░░░░░  (7pt, full width, state color)
   ↓ 1.2 MB/s · 12m                                     (secondary, 10.5pt)
```

### Layer 1 — name (R1)

- `HStack(top)` with a 6pt `Circle` status dot, then the name.
- Name: `.font(.system(size: 12, weight: .medium))`, `lineLimit(2)`,
  `truncationMode(.tail)`, `fixedSize(horizontal: false, vertical: true)`
  so the row grows instead of clipping.
- Dot color: `Self.color(for: state)` (existing mapping, unchanged).
  This replaces the SF Symbol; `symbol(for:)` becomes dead code and is
  removed.
- On 2-line names the dot stays top-aligned (baseline of line 1).

### Layer 2 — progress (R2)

- Full-width `GeometryReader`-free layout: `HStack { bar; Text(pct) }`.
- Bar: `Capsule` track at `stateColor.opacity(0.15)`, `Capsule` fill at
  `stateColor`, height **7pt**. For `.seeding`/complete torrents (progress
  ≥ 1) the bar renders at full width; still visible, colored green.
- Percentage text: `"\(Int((progress * 100).rounded()))%"`,
  `.monospacedDigit`, 10pt, `.secondary`, trailing. 100% complete torrents
  show `100%` (not "Done") — simple and unambiguous across languages.

### Layer 3 — info line (R3)

One line, 10.5pt, `.secondary`, monospaced digits, built by a new **pure**
helper so `--selftest` can assert it (AC5):

```swift
// New, in TorrentSummary extension or L10n — pure, testable
static func infoLine(down: Int64, up: Int64, state: TorrentState,
                     etaSeconds: Int64?) -> [String]   // segments
```

Composition rules (exact strings; separators added by the view as
`Text(seg1) · Text(seg2)` or single Text):

| state | segments |
| --- | --- |
| `.downloading` | `↓ rate` (if down > 0), `↑ rate` (if up > 0), `eta` (if non-nil) — e.g. `↓ 1.2M · 12m`, or `↓ 1.2M · ↑ 50.0K · 30m` when seeding while downloading |
| `.seeding` | `↑ rate` (if up > 0); if up == 0 → localized state word "Seeding" |
| `.stalled` | localized "Stalled" |
| `.queued` | localized "Queued" |
| `.checking` | localized "Checking" |
| `.paused` | localized "Paused" |
| `.error` | localized "Error" |
| `.other` | localized "Unknown" (existing pattern) |

- Zero speed → that arrow segment is omitted entirely (AC3).
- Segments joined with ` · ` (space-dot-space).
- State words go through `L10n` (keys = English text, R9 fallback works).
- ETA reuses `L10n.eta`.

### Separators (R5)

- Delete the inter-row hairlines in `section(_:)` (the `if index > 0`
  hairline block). Rows get `.padding(.vertical, 5)`; the LazyVStack
  spacing handles rhythm.

## Pure helper placement & testing

- `infoLine` logic (which segments, in which order, given
  speeds/state/eta) → pure static func next to `TorrentSummary.sorted` in
  `PTMonitorCore/Model/TorrentSummary.swift` (returns `[String]` of
  already-localized segments — needs `L10n`, which lives in the app
  target… **so instead** place the *decision* function in
  `PTMonitorCore` (enum of segment kinds, no strings) and the
  *stringification* in `PanelView`/`L10n`):

```swift
// PTMonitorCore — pure, selftest-assertable
public enum TorrentRowInfoSegment: Equatable, Sendable {
    case down(Int64), up(Int64), eta(Int64), stateWord(TorrentState)
}
public static func infoSegments(state: TorrentState, down: Int64, up: Int64,
                                etaSeconds: Int64?) -> [TorrentRowInfoSegment]
```

- `--selftest` adds checks: zero-speed omission, downloading with/without
  eta, seeding word fallback, each idle-state word mapping.
- Existing helpers `symbol(for:)` removed; `color(for:)` and `etaText`
  stay.

## `--preview-panel <out.png>` (R7)

- New file `Sources/PTMonitor/App/PanelPreview.swift` (app target; uses
  AppKit/SwiftUI freely):
  - `PanelPreview.fixtureSettings()` / `fixtureMonitor()` — an in-memory
    `SettingsStore` + `MonitorStore` are awkward (UserDefaults/polling), so
    instead build a lightweight fixture path: `PanelView` takes
    `settings: SettingsStore` / `monitor: MonitorStore` (ObservedObject).
    Simplest macOS-12-safe approach: create the two stores with a fixture
    `UserDefaults` suite (`UserDefaults(suiteName: "preview")`, inject
    servers, inject a `MonitorStore` whose `statuses` we set directly via
    an internal test hook (`MonitorStore.setPreviewStatuses(…)` — an
    `#if DEBUG`-style plain method; the binary is the same debug build, so
    just make it an internal method on MonitorStore that production never
    calls). No pollers are started.
  - Render: `NSHostingView(rootView:)`, set explicit frame (PanelView.preferredWidth
    × fittingSize), grab `NSBitmapImageRep` via
    `cacheDisplay(in:to:)` (renders **light**; for dark, render the same
    view with `.environment(\.colorScheme, .dark)` into a second bitmap).
  - Write PNGs: `<out>` and dark variant `<stem>-dark.<ext>` (AC8).
  - `usage` line added to `main.swift` printUsage; argv handling mirrors
    the existing `--probe` block: `if arguments.contains("--preview-panel")`.
- Fixture torrents cover every `TorrentState` case plus a very long name,
  a 100%-complete torrent, and zero-speed rows (AC8).

## Compatibility / risks

- `NSHostingView.cacheDisplay` with SwiftUI can occasionally miss
  TimelineView-driven content (freshness label); acceptable for a debug
  render — the timeline text is not part of the redesigned area.
- `SettingsStore` init: verify it does not write defaults at init before
  pointing it at a scratch suite; if it always uses `.standard`, the
  preview must instead populate `servers` via its normal API on the
  scratch suite. Check during implementation.
- Row height grows (2-line names) → more vertical space per row; the
  100-row cap and `LazyVStack` keep perf bounded (spec §7 contract).
- Rollback: single-file revert of `PanelView.swift` + removal of the two
  new small files; no cross-layer surface changes.

## Trade-offs

- Dot instead of SF Symbol: less literal meaning per glyph (a clock icon
  said "queued"), but the info line now always carries the state word, so
  no information is lost — the icon was redundant with the new layer 3.
- Fixed percentage text next to bar (not inside): keeps the bar a plain
  two-capsule draw, no text-measuring inside the bar, no macOS-12 issues.
