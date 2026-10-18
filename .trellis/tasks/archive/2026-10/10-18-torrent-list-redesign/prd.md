# Redesign the torrent list visual design

## Goal

Make the torrent rows in the dropdown panel look modern and readable: the
torrent name should display better (not a single hard-truncated line), the
progress bar should be thicker and more informative, and the speed/ETA/detail
information should be simpler and visually calmer. Visual quality is the
deliverable; no behavior/data changes.

## Background

User complaint (2026-10-18): unhappy with the current look & feel of the
torrent list — the name display, the too-thin progress bar, and the cluttered
speed/ETA info.

Current row anatomy (`Sources/PTMonitor/App/PanelView.swift`, `row(_:)` +
`PillMeter`):

```
[SF Symbol] Very long torrent name gets middle-truncated in one line…
           [4pt pill meter, 90pt] [↓1.2M ↑340K, fixed 96pt] [ETA, fixed 52pt]
```

Problems:

- Single-line name with middle truncation wastes available width and hides
  the distinguishing parts of long names.
- The 4pt-high, 90pt-wide pill progress bar is nearly invisible and carries
  no percentage.
- The detail line always renders both arrows even when one speed is 0, uses
  fixed-width trailing columns that leave empty gray gaps, and mixes
  inconsistent font sizes.
- Hairline separators between every row add line noise.

## Requirements

- R1 (name): torrent name may wrap to 2 lines (`lineLimit(2)`, tail
  truncation), sized/weighted to be the row's primary text.
- R2 (progress): thicker progress bar (target ~7pt), full row width, filled
  with the state color; show the numeric percentage (monospaced digits).
- R3 (info line): one secondary line showing only what is meaningful:
  - downloading: **every direction that is moving** (`↓` and/or `↑`) + ETA
    when available — a torrent can seed while it downloads, and hiding that
    upload rate loses real information
  - seeding: `↑ rate` only
  - paused/queued/checking/stalled/error: a short localized state word
    (e.g. "Paused") instead of zero-valued arrows
  - never render an arrow for a zero speed
- R4 (state indication): keep per-state color coding; replace the SF Symbol
  glyph with a compact state-colored dot next to the name (exact treatment
  finalized in design.md).
- R5 (separators): remove per-row hairlines in favor of row spacing.
- R6 (fixtures unchanged): sorting, filtering, 100-row cap, LazyVStack,
  read-only rows (R8 of app-conventions) all unchanged — this is a
  presentation-only change inside the panel.
- R7 (preview mode): new `--preview-panel <out.png>` argv mode renders
  `PanelView` with built-in fixture data (light and dark variants) to PNG
  via `NSHostingView` + `NSBitmapImageRep` (macOS-12-compatible; not
  `ImageRenderer`, which is 13+). Debug-only; the menu bar agent path and
  `--selftest` behavior are untouched. Fixture data lives in code so the
  render needs no network/server.

## Acceptance Criteria

- [ ] AC1: Names up to 2 lines render fully where width allows; longer names
      tail-truncate at line 2 (no middle truncation).
- [ ] AC2: The progress bar renders at the increased thickness, spans the
      row width, and a monospaced-digit percentage sits at its right end.
- [ ] AC3: A torrent with 0 down speed shows no `↓` arrow (and vice versa
      for up); paused/queued/etc. rows show a localized state word, not
      `— / —`.
- [ ] AC4: Light and dark color schemes both look correct (semantic colors,
      no hardcoded dark-only values).
- [ ] AC5: `swift build` warning-free; `swift run PTMonitor --selftest`
      passes; any new pure formatting helper gets a selftest check.
- [ ] AC6: New/changed user-visible strings go through `L10n` (R9
      localization contract); English fallback works with no .lproj match.
- [ ] AC7: Read-only behavior preserved — no new controls on torrent rows.
- [ ] AC8: `--preview-panel <out.png>` writes readable PNGs (light variant
  at `<out>`, dark at `<out>` with `-dark` inserted before the extension)
  with fixture torrents in every normalised state, exits 0, and touches no
  network/Keychain.

## Out of Scope

- Sorting/filter UI, "show all" actions, any control endpoints (R8).
- Aggregate grid, header, footer, empty states (their look may stay as is).
- Per-server section header redesign (may get minor spacing tweaks only).

## Decisions

- Q1 (resolved 2026-10-18): include `--preview-panel` — approved by Howard;
  faster screenshot-driven iteration outweighs the ~60–80 extra debug-only
  lines.
