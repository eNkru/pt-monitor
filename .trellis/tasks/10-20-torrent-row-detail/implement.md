# Implement — Torrent row detail

Ordered so each step leaves a compiling, checkable tree. Steps 1–3 deliver the
site (R1/R3/R4/R5), 4–5 the detail line (R6), 6–7 the expanded row (R7/R8).

## 1. Core model + pure helpers

- [ ] `Sources/PTMonitorCore/Model/TorrentSummary.swift`
  - Add optional fields from design §2, all with defaults (existing call sites
    and selftest expectations must keep compiling).
  - Add `TrackerStatus` enum (`.working`, `.notWorking`).
  - Add `site(fromAnnounceURL:)` (design §3) and `hoistedSite(for:)` (design §5).
  - Add `expandedLines(for:)` returning `[TorrentDetailLine]` (design §6).

## 2. Parsers

- [ ] `QBittorrentClient.swift`: `summaries(fromTorrents:trackers:)` reads the new
  keys; `snapshot(fromMainData:)` passes `root["trackers"]`.
- [ ] `TransmissionClient.swift`: extend `TransmissionParser.torrentFields`;
  parse the new keys in the torrent mapping.

## 3. Panel: site on the detail line

- [ ] `PanelView.row(_:)`: detail line becomes
  `HStack { infoText; Spacer(minLength: 8); site }` with `layoutPriority(1)` +
  `fixedSize()` on the site (design §4).
- [ ] `PanelView.section(_:)`: compute `hoistedSite` over the rendered rows; pass
  it to `sectionHeader` and suppress the per-row site when non-nil.
- [ ] `L10n`: any new user-visible string goes through `s(...)` keys (English
  text as the key, per `L10n` convention).

## 4. Panel: richer contextual detail line

- [ ] Confirm/extend `infoSegments` only if the decided segment rules need it —
  the collapsed line stays transfer-state only; the site is not a segment.

## 5. Selftest for site + hoisting

- [ ] `SelfTest.rowChecks`: add `site(fromAnnounceURL:)` cases — with/without
  scheme, with port, with path/query, `tracker.`/`announce.`/`t.` prefixes,
  `nil`/empty input, a bare host, and a UDP announce URL.
- [ ] Add `hoistedSite(for:)` cases: all-same ⇒ value; two sites ⇒ nil; one row
  missing a site ⇒ nil; empty list ⇒ nil.
- [ ] Extend the inline qBittorrent `sync/maindata` fixture with a `trackers`
  map and the new torrent fields; assert the parsed values (including
  `ratio: -1` ⇒ nil and `category: ""` ⇒ nil).
- [ ] Extend the inline Transmission fixture with `trackers`, `totalSize`,
  `uploadRatio`, `errorString`; assert the parsed values and `error: 0` ⇒ no
  error message.

## 6. Panel: expanded row

- [ ] `PanelView`: `@State expandedTorrentID: String?`; row click toggles it,
  another row replaces it; render the detail block when it matches.
- [ ] `L10n`: labels for Size / Ratio / Peers / tracker status / category / error.
- [ ] `SelfTest`: `expandedLines(for:)` cases — full data, all-nil data (no
  lines), ratio `-1`, working vs not-working tracker, failed torrent with an
  error string.

## 7. Spec update (required, Phase 3.3)

- [ ] `.trellis/spec/macos/app-conventions.md`
  - Amend the R8/AC18 line (§`Read-only`) per PRD R11 to permit *view-state* row
    interactions, and record that expansion resets per panel open and grows the
    panel downward.
  - Document the row's detail line as `info text ← … → site`, the uniform-site
    hoisting rule, and the expanded-row field set.
  - Note that `TorrentSummary`'s new fields are nil-means-unreported.

## Validation

```bash
swift build                                     # warning-free
swift run PTMonitor --selftest                  # all checks pass
swift run PTMonitor --selftest | tail -3        # confirm no regressions
```

Manual: open the panel against the live NAS; confirm
(a) collapsed row height and panel width are unchanged,
(b) the site appears right-aligned and survives a long name/info line,
(c) a single-site server shows the site in the section header only,
(d) clicking a row expands it without closing the panel, clicking another row
moves the expansion, and reopening the panel starts collapsed.

## Risky files / rollback points

- `PanelView.swift` — the row is the perf-sensitive path; keep it lazy, no
  `GeometryReader`, no eager `VStack` (spec §`Torrent list rendering`).
- `QBittorrentClient.summaries(fromTorrents:)` signature change — update the
  selftest call sites in the same commit.
- Rollback: commit site → detail line → expanded row separately (design §9).
