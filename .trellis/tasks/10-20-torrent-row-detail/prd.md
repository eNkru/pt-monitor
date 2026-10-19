# Torrent row detail: expand-on-click, richer info line, site label

## Goal

Show more per-torrent information in the menu-bar panel **without squeezing the
380pt layout**: a richer always-on detail line, click-to-expand full detail on a
single row, and the PT site derived from the torrent's tracker announce URL shown
in the main panel.

User value: at a glance see what a torrent is doing and where it came from,
without opening the NAS web UI, and without the panel getting wider or noisier.

## Background / confirmed facts (from code inspection)

- Panel is fixed at `PanelView.preferredWidth = 380` (`PanelView.swift:38`).
- A torrent row is 3 layers: state dot + 2-line name, full-width capsule
  progress bar + percentage, and one detail line
  (`PanelView.swift:337-380`). Which detail segments appear is decided by the
  pure helper `TorrentSummary.infoSegments(...)` (`TorrentSummary.swift:126`),
  covered by `--selftest`. Spec: `.trellis/spec/macos/app-conventions.md:270-283`.
- **Read-only contract** (`app-conventions.md:288`): torrent rows and sections
  carry no actions; only footer rows act. This task amends that wording — see
  R11.
- **Panel hosting view is rebuilt fresh on every `show()`**
  (`app-conventions.md:250-257`), so any per-row UI state (expanded row) resets
  each time the panel opens. Scroll position already resets by design.
- **In-panel clicks do not dismiss the panel**: `PanelController`'s dismissal
  monitors only hide on clicks outside the panel frame
  (`PanelController.swift:221-232`), and `relayoutIfVisible()` re-fits the panel
  when content height changes (`PanelController.swift:180-187`), keeping the top
  edge anchored.
- **Extra data is free on the wire — no new requests, no extra polling:**
  - qBittorrent: `sync/maindata?rid=0` is always a full update, so every torrent
    entry already contains `ratio`, `total_size`, `num_seeds`/`num_complete`,
    `num_leechs`/`num_incomplete`, `uploaded`, `downloaded`, `category`, and the
    top-level `trackers` map (hash → `[{url, tier, status}]`) arrives too.
    Currently only `name`, `state`, `progress`, `dlspeed`, `upspeed`, `eta` are
    read (`QBittorrentClient.swift:168-186`).
  - Transmission: same single `torrent-get` RPC; new fields are appended to
    `TransmissionParser.torrentFields` (`TransmissionClient.swift:8-11`).
    `error`/`errorString` are **already requested and then discarded**, so a
    failed torrent can report why for zero cost.

## Requirements

### Site label

- R1. The PT site is derived from the torrent's **tracker announce URL** and
  shown in the main panel. No extra HTTP request may be introduced for it.
- R2. Displayed as the **raw host with known prefixes stripped** (`tracker.`,
  `announce.`, `t.`, `www.`) — e.g. `hdchina.org`. No friendly-name table and no
  registrable-domain (public-suffix) reduction.
- R3. The site is taken from the **first entry of the torrent's announce list**
  as delivered by the API (qBittorrent `trackers[hash][0].url`, Transmission
  `trackers[0].announce`). No tier preference, no "working tracker" selection.
  An empty list means no site is shown for that torrent (no placeholder text).
- R4. The site sits **right-aligned at the trailing end of the existing detail
  line** (`HStack`: info text, `Spacer(minLength: 8)`, site), in the same small
  secondary style. It must survive detail-line truncation, so the info text
  truncates first. No new row, no chip beside the name.
- R5. **Uniform-site hoisting.** If every rendered torrent in a server section
  resolves to the same site, that site is shown once in the section header
  (beside the speeds) and omitted from the rows. Otherwise (two or more distinct
  sites, or any row without a site) it is shown per row.

### Detail line

- R6. The collapsed torrent row keeps its richer contextual detail line: which
  segments are shown is chosen by torrent state, computed in a pure helper
  (`infoSegments`, already in place).

### Expanded row

- R7. A single torrent row can be expanded in place to reveal the full detail
  set; at most one row is expanded at a time.
- R8. **Expanded row field set**:
  - `Size` — total size, plus downloaded bytes / progress.
  - `Ratio` — ratio, plus uploaded and downloaded totals.
  - `Peers` — seeders and leechers.
  - When applicable and already on the wire: tracker status (working / not
    working), category, and the error string for failed torrents.
  All values come from the existing poll response; adding a field must not add
  an HTTP request.

### Cross-cutting

- R9. Neither the site label nor the detail line may increase the panel width or
  the collapsed row height.
- R10. All new formatting decisions live in pure, `--selftest`-covered helpers in
  `PTMonitorCore`, not in the view. Nil means "server did not report it", never
  zero.
- R11. **Read-only contract amendment.** The spec's row-anatomy rule is updated
  to permit *view-state* interactions on rows (expand/collapse) that perform no
  network call and mutate nothing on the server. Server actions (pause / resume /
  remove / add) remain forbidden.

## Out of scope

- Any control action on torrents (pause/resume/remove/add) — see R11.
- User-facing sort UI (existing fixed sort stays).
- A public-suffix-list / registrable-domain implementation.
- Speed history graphs, per-torrent detail windows, or panel widening.
- Friendly site names (domain → brand mapping).

## Acceptance Criteria

- [ ] AC1. With a torrent whose announce URL is
  `https://tracker.hdchina.org/announce.php?passkey=x`, the row's detail line
  shows `hdchina.org` right-aligned, and the info text truncates before the site
  does.
- [ ] AC2. The panel width stays 380pt and the collapsed row height is unchanged
  from the current build (R9).
- [ ] AC3. On a server whose rendered torrents all share one site, that site
  appears once in the section header and not on any row. On a server with two
  distinct sites, it appears on each row instead.
- [ ] AC4. A torrent with an empty announce list shows no site anywhere — no
  placeholder, no em dash (R3).
- [ ] AC5. Clicking a row expands it in place showing Size / Ratio / Peers (plus
  tracker status, category, and error string when present); the panel does not
  close. Clicking a second row collapses the first.
- [ ] AC6. Reopening the panel shows every row collapsed (view state is not
  persisted).
- [ ] AC7. A failed torrent with an error string shows that string in its
  expanded block; a healthy torrent shows none.
- [ ] AC8. No new HTTP request is issued for any of this: the poll count and
  cadence against the NAS are unchanged (verified by inspecting the request log
  / client code paths).
- [ ] AC9. `--selftest` covers `site(fromAnnounceURL:)`, the uniform-site
  hoisting helper, and the expanded-line formatter, each with explicit expected
  values; `swift build` is warning-free.
- [ ] AC10. `.trellis/spec/macos/app-conventions.md` reflects R11 and documents
  the site placement, hoisting rule, and expanded field set.
