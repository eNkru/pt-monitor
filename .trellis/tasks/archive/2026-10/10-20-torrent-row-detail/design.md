# Design — Torrent row detail

## 1. Boundaries

All three deliverables split cleanly along the existing layer line:

| Layer | Responsibility |
|---|---|
| `PTMonitorCore/Model/TorrentSummary.swift` | New fields + **pure** decision helpers (no strings, no SwiftUI) |
| `PTMonitorCore/Client/{QBittorrent,Transmission}Client.swift` | Parse the new fields out of the response already fetched |
| `PTMonitor/App/PanelView.swift` | Render segments/site; own the expanded-row view state |
| `PTMonitor/App/L10n.swift` | Localized text for the new segments |

Rule inherited from the current row design (`app-conventions.md:270-283`): the
*decision* of what to show lives in Core as a string-free value type; the *text*
lives in the app target. Anything else becomes untestable.

## 2. Data model

`TorrentSummary` gains optional fields, all defaulted so existing call sites and
`--selftest` expectations keep compiling:

```swift
public struct TorrentSummary {
    // ... existing: id, name, state, progress, downSpeed, upSpeed, etaSeconds
    public var totalSize: Int64?      // nil = server did not report
    public var downloaded: Int64?
    public var uploaded: Int64?
    public var ratio: Double?         // qBittorrent sends -1 for "n/a"
    public var seeders: Int?          // connected seeds
    public var leechers: Int?
    public var site: String?          // derived host, nil when no tracker
    public var trackerStatus: TrackerStatus?  // .working / .notWorking / nil
    public var category: String?      // empty string normalised to nil
    public var errorMessage: String?  // Transmission errorString
}
```

`TrackerStatus` is a small `enum` in Core (`.working`, `.notWorking`) — a
string-free decision, so `--selftest` can assert it without touching L10n.

**Nil means "server did not report it", never "zero".** Every renderer skips a
nil field rather than printing `0 B`; that keeps the expanded row honest across
qBittorrent versions and Transmission field gaps.

## 3. Site extraction (R1, R3)

Pure helper in Core, `--selftest`-covered:

```swift
public static func site(fromAnnounceURL url: String?) -> String?
```

Steps: trim → drop scheme (`https://`, `http://`, `udp://`) → cut at first `/`,
`?`, or `:` (port) → lowercase → strip one leading label from
`{tracker, announce, t, www, tr}` (repeat until no match, max 2 iterations) →
`nil` if empty.

Deliberate non-goals: no public-suffix list, no registrable-domain reduction, no
friendly-name table (PRD R2). `tracker.hdchina.org` → `hdchina.org`;
`announce.torrentleech.org` → `torrentleech.org`; `hdchina.org` unchanged.

Sources:
- qBittorrent: top-level `trackers[hash]` array → `[0]["url"]`. The per-torrent
  `tracker` field is WebAPI-version dependent, so it is **not** used.
- Transmission: `trackers[0]["announce"]`.

Both are already in the current response (`rid=0` is always a full update, so
the top-level `trackers` map is present on every poll). No new request.

## 4. Detail line (R4, R6)

`infoSegments(...)` keeps its current signature and semantics; the site is
**not** a segment — it is a separate right-aligned element of the same line, so
the segment list stays purely about transfer state and the existing checks keep
their meaning.

Layout change in `PanelView.row(_:)`:

```
HStack(spacing: 8) {
    Text(infoText)  .lineLimit(1).truncationMode(.tail).layoutPriority(0)
    Spacer(minLength: 8)
    if let site { Text(site).lineLimit(1).fixedSize().layoutPriority(1) }
}
```

`layoutPriority(1)` + `fixedSize()` on the site is what guarantees the site wins
the width contest and the info text truncates first (R4). Collapsed row height
is unchanged (R9) — the site joins an existing line.

## 5. Uniform-site hoisting (R5)

Pure helper over the **rendered** rows of one section (post active-only filter,
post 100-row cap):

```swift
public static func hoistedSite(for torrents: [TorrentSummary]) -> String?
```

Returns the shared site only when every row has a non-nil site and they are all
equal; otherwise `nil` (⇒ per-row). An empty list returns `nil`. The section
header renders the returned value beside the speeds; rows render the site only
when the helper returned `nil`.

Consequence worth naming: appearance is data-dependent — a mixed-site server
that settles to one site flips from per-row to header between polls. Accepted;
the alternative is permanent repetition in the common single-site case.

## 6. Expanded row (R7, R8)

View state, one value in `PanelView`:

```swift
@State private var expandedTorrentID: String?   // torrent.id
```

- Click on a row toggles it; opening another row replaces the value (R7: at most
  one expanded).
- Rendering: when `expandedTorrentID == torrent.id`, insert a detail block
  (Size / Ratio / Peers + optional tracker status, category, error) below the
  progress bar. Everything else about the row is unchanged.
- Formatting of each value is a pure Core helper (R10), e.g.
  `expandedLines(for: TorrentSummary) -> [TorrentDetailLine]` returning a
  string-free `enum { case size(...), ratio(...), peers(...), trackerStatus(...),
  category(String), error(String) }`, so `--selftest` asserts which lines appear
  and in what order; the app turns each into localized text.

**R11 contract amendment (decided).** Spec `app-conventions.md:288` currently says
rows carry no actions. Amend to: rows may carry *view-state* interactions
(expand/collapse) that perform no network call and mutate nothing on the server;
they must never carry server actions. Also record the two consequences:
expansion resets on every panel open (hosting view is rebuilt, §`show()`), and
expansion grows panel height downward because `PanelController.layout()` keeps
the top edge anchored and re-fits via `relayoutIfVisible()`.

**Click safety.** `PanelController`'s dismissal monitors only hide on clicks
*outside* the panel frame (`PanelController.swift:221-232`), so an in-panel row
click will not close the panel. Verified, not assumed.

## 7. Parser changes

- `QBittorrentParser.summaries(fromTorrents:)` gains a `trackers:` parameter
  (the top-level map) and reads the extra per-torrent keys. Existing call sites
  in `snapshot(fromMainData:)` pass the parsed map. Keys: `total_size`,
  `downloaded`, `uploaded`, `ratio` (`-1` ⇒ nil), `num_seeds`/`num_leechs`
  (`num_complete`/`num_incomplete` as fallback when the connected counts are
  absent), `category` (empty ⇒ nil), `trackers[hash][0].url`, and
  `trackers[hash][0].status == 2` ⇒ `.working`.
- `TransmissionParser.torrentFields` gains `"totalSize"`, `"uploadedEver"`,
  `"downloadedEver"`, `"uploadRatio"`, `"peersSendingToUs"`,
  `"peersGettingFromUs"`, `"trackers"`, `"error"`, `"errorString"`. Same single
  RPC. `uploadRatio` `-1` ⇒ nil; `errorString` only when `error != 0`.

## 8. Compatibility / risk

- **Transmission old RPC**: an unrecognised field name in `fields` is tolerated
  by every supported version; unknown keys are simply absent in the response,
  which maps to `nil` — the UI degrades to fewer expanded lines.
- **qBittorrent < 2.1.1**: `free_space_on_disk` stays gated as today; the new
  torrent fields are present in all supported versions (≥2.0.0 is already
  enforced at `QBittorrentClient.swift:322`).
- **No new network surface**: the only way this feature could "spam the NAS" is
  a new request; there is none. Polling cadence is untouched.
- **Perf**: the panel's bounded/lazy rendering contract is unchanged — no new
  eager `VStack`, no `GeometryReader` per row, and the site/expanded block are
  plain `Text`/`HStack`.

## 9. Rollback

Each deliverable is independent and lands in separate files/commits:
site (Core helper + parsers + row line) → detail line (Core + view) → expanded
row (view state + Core formatter). Reverting the expanded-row commit alone leaves
site + detail line working, since neither depends on the view state.
