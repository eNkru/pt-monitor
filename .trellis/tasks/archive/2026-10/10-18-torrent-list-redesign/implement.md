# Implementation Plan — Torrent List Redesign

## Ordered checklist

1. **Pure segment helper** (`PTMonitorCore/Model/TorrentSummary.swift`)
   - Add `TorrentRowInfoSegment` enum + `TorrentSummary.infoSegments(state:down:up:etaSeconds:)`.
   - Add `--selftest` checks in `Sources/PTMonitorCore/Diagnose/SelfTest.swift`:
     zero-speed omission, eta presence/absence, seeding word fallback,
     all idle-state mappings.
   - Validate: `swift build && swift run PTMonitor --selftest` (stub a
     SettingsStore-free path — selftest runs before AppKit init).

2. **L10n state words** (`Sources/PTMonitor/App/L10n.swift`)
   - Add `stateWord(_ state: TorrentState) -> String` with keys = English
     words ("Downloading", "Seeding", "Stalled", "Queued", "Checking",
     "Paused", "Error", "Unknown"); add zh-Hans entries to
     `Resources/*.lproj/Localizable.strings` if present (check during impl).

3. **Row redesign** (`Sources/PTMonitor/App/PanelView.swift`)
   - Replace `row(_:)` internals with the 3-layer layout (design §row):
     dot + 2-line name / 7pt full-width bar + % / info line from
     `infoSegments`.
   - Delete `PillMeter` and `symbol(for:)`; keep `color(for:)`, `etaText`.
   - Remove inter-row hairlines in `section(_:)`; set row padding.
   - Add percentage text helper (monospaced digits).

4. **Preview mode** (new `Sources/PTMonitor/App/PanelPreview.swift`,
   `main.swift`)
   - `--preview-panel <out.png>` → fixture stores + statuses (check
     `SettingsStore` init behavior first, design §Compatibility), render
     light PNG at `<out>`, dark at `<stem>-dark.<ext>` via
     `NSHostingView.cacheDisplay`.
   - Wire argv + usage line in `main.swift` next to the `--probe` block.

5. **Visual iteration loop** (uses step 4)
   - Render, inspect PNG (read tool), tweak spacing/thickness/typography,
     repeat until AC1–AC4 hold in both schemes. 2–3 iterations expected.

6. **Full check** (trellis-check scope)
   - `rm -rf .build && swift build` warning-free (Sendable/MainActor).
   - `swift run PTMonitor --selftest` green.
   - `swift run PTMonitor --preview-panel /tmp/ptmon-preview.png` works.
   - `./scripts/build-app.sh` still assembles.

## Validation commands

```bash
swift build
swift run PTMonitor --selftest
swift run PTMonitor --preview-panel /tmp/ptmon-preview.png
rm -rf .build && swift build          # warning-free gate
./scripts/build-app.sh
```

## Risky files / rollback points

- `PanelView.swift` — the only existing file materially edited; revert it
  plus delete `PanelPreview.swift` + helper additions to roll back fully.
- `SelfTest.swift` — additive checks only; a failure here blocks commit.
- `main.swift` — one argv block; must exit(0) and never fall through to
  the agent path.

## Before `task.py start`

- [ ] Curated `implement.jsonl` / `check.jsonl` entries (real spec refs).
- [ ] Final planning summary approved by user.
