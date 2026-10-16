# Design — macOS Menu Bar PT Monitor

Derived from `research/apis.md` (authoritative, with citations). This file is the
decision record: what we build, why, and what we deliberately do not build.

## 1. Stack decision

| Option | Verdict |
| --- | --- |
| Swift + AppKit + SwiftUI, SwiftPM | **Chosen.** No runtime to install, ~1 MB binary, native status item, builds with Command Line Tools only (verified). |
| SwiftUI `App` lifecycle + `MenuBarExtra` | **Rejected.** `MenuBarExtra` is macOS 13+; deployment target is 12. |
| Electron / Tauri | **Rejected.** Hundreds of MB, a bundled runtime, and a worse status item. No benefit for a 500-line poller. |
| Python + rumps | **Rejected.** Needs a user-managed interpreter and pyobjc; packaging is the hard part. |

Consequences of CLT-only: no `xcodebuild`, no `.xcodeproj`, no asset catalog, no
automatic signing. We assemble the `.app` bundle ourselves in
`scripts/build-app.sh`.

## 2. Module structure

Two targets. A **library** (`PTMonitorCore`) holds everything, and a thin
**executable** (`PTMonitor`) holds only `main.swift`. The split keeps the
`main.swift` top-level-code entry point out of the reusable code, so a future
XCTest suite could `@testable import PTMonitorCore` without fighting an
executable target.

```
Package.swift                      swift-tools-version:5.7, platforms: [.macOS(.v12)]
Sources/PTMonitorCore/
  Model/ServerConfig.swift         Codable value type + ServerKind enum
  Model/TransferSnapshot.swift     normalised cross-client snapshot
  Model/ServerStatus.swift         per-server state enum + error causes
  Client/TorrentClient.swift       protocol + errors + shared JSON helpers
  Client/QBittorrentClient.swift   WebUI API v2
  Client/TransmissionClient.swift  RPC (session-id handshake)
  Client/HTTPTransport.swift       URLSession config, self-signed trust, credentials
  Store/SettingsStore.swift        UserDefaults-backed server list
  Store/KeychainStore.swift        password storage
  Store/MonitorStore.swift         @MainActor observable poller + snapshots
  Format/ByteRateFormatter.swift   "1.2M" / compact / tabular-digit text
  Diagnose/ProbeRunner.swift       headless --probe mode (R11)
  Diagnose/SelfTest.swift          --selftest checks + recorded API fixtures
Sources/PTMonitor/
  main.swift                       argv dispatch + NSApplication bootstrap
  App/AppDelegate.swift
  App/StatusItemController.swift   NSStatusItem + dynamic NSMenu
  App/PreferencesWindowController.swift
  App/MenuBuilder.swift
  App/PreferencesView.swift        SwiftUI
  App/ServerEditorView.swift       SwiftUI
  App/TorrentListView.swift        SwiftUI torrent list, embedded in the dropdown (R12)
Resources/Info.plist
scripts/build-app.sh
```

There is **no test target**: `swift test` is unusable under Command Line Tools
(`error: XCTest not available`, see `prd.md` → Background). Automated checks live
in `Diagnose/SelfTest.swift` and run via `swift run PTMonitor --selftest`, which
exits non-zero on the first failure. The fixtures are Swift string literals
holding the documented response shapes from `research/apis.md`; they are kept
next to the self-test so a future XCTest suite can reuse them verbatim.

## 3. Domain model

Both APIs are normalised into one shape; nothing above the client layer knows
which API a server speaks.

```swift
enum ServerKind: String, Codable { case qbittorrent, transmission }

struct ServerConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: ServerKind
    var name: String          // display name, defaults to kind
    var host: String
    var port: Int
    var useTLS: Bool
    var allowInsecureTLS: Bool
    var username: String
    var isEnabled: Bool
}
// password is NOT here — it lives in Keychain keyed by id.

struct TransferSnapshot: Equatable {
    var downSpeed: Int64          // bytes/s, global
    var upSpeed: Int64            // bytes/s, global
    var activeTorrents: Int
    var totalTorrents: Int
    var freeSpace: Int64?         // nil when the server can't report it
    var connectionState: ConnectionState   // connected/firewalled/disconnected/unknown
    var fetchedAt: Date
    var torrents: [TorrentSummary] = []    // per-torrent summaries for the list window (R12)
}

/// Normalised per-torrent summary (R12). Both APIs map onto this; nothing above
/// the client layer knows which API a server speaks.
enum TorrentState: String, Codable, Equatable, Sendable {
    case downloading, seeding, stalled, queued, checking, paused, error, other
}

struct TorrentSummary: Equatable, Sendable {
    var id: String                // qBittorrent hash / Transmission id as string
    var name: String
    var state: TorrentState
    var progress: Double          // 0…1
    var downSpeed: Int64          // bytes/s
    var upSpeed: Int64            // bytes/s
    var etaSeconds: Int64?        // nil = unknown/infinite (API sentinel values)
}

enum ServerStatus {
    case disabled
    case connecting
    case online(TransferSnapshot)
    case failed(ServerFailure)
}

enum ServerFailure: Equatable {
    case unreachable(String)      // DNS/connection refused/timeout/TLS
    case auth(String)             // credentials rejected
    case protocolViolation(String)
    case serverError(String)      // e.g. Transmission 403/421, qBittorrent banned
}
```

`ServerFailure` exists so AC7/AC8 can assert on a *cause*, and so the menu can
print an actionable hint (e.g. Transmission `421` → "name not in
rpc-host-whitelist; connect by IP or enable auth").

## 4. Client layer

```swift
protocol TorrentClient: Sendable {
    func fetchSnapshot() async throws -> TransferSnapshot
    func testConnection() async throws -> String   // returns a version string
}
```

Each poll constructs a fresh client (cheap) or reuses one per server; the client
owns its auth state (qBittorrent `SID` cookie, Transmission session id).

### 4.1 qBittorrent

- Login: `POST /api/v2/auth/login`, `application/x-www-form-urlencoded`,
  `username=&password=`. **Send no `Origin` and no `Referer`** — CSRF protection
  is on by default and the server skips the check only when both are absent.
- **Wrong credentials return HTTP 200 with body `Fails.`**, not 401. Treat that
  as `.auth`. Also treat a login `Ok.` as *not* proof of credentials, because the
  localhost/subnet auth bypass makes `login` return `Ok.` for any password.
- Poll: `GET /api/v2/sync/maindata?rid=0` → one response containing
  `server_state` plus the full torrent map. **`rid=0` every poll** (always a full
  snapshot). We deliberately do not implement `rid` deltas: they need a
  merge-with-removals and are a correctness risk for a status widget.
- Do **not** poll `/transfer/info` — it returns only 8 keys and lacks all-time
  totals and `free_space_on_disk`.
- Field mapping: `dl_info_speed`/`up_info_speed` → speeds;
  `connection_status` (string) → `ConnectionState`;
  `free_space_on_disk` → `freeSpace` **only if WebAPI ≥ 2.1.1**, else `nil`.
  `dl_info_data`/`up_info_data` are *session* counters, not lifetime — unused.
- Active/total torrent counts are derived from `torrents[*].state`: active
  = `state` in {`downloading`,`metaDL`,`forcedDL`,`uploading`,`forcedUP`,`stalledDL`,`stalledUP`}.
- Graceful degradation: after login, `GET /api/v2/app/webapiVersion` once, cache
  it, and gate optional fields on it. Servers older than API 2.0 (qBittorrent
  < 4.1.0) are rejected up front with a clear message.
- On a `401` from a non-login endpoint: re-login once and retry once, then fail.
  Never loop.

### 4.2 Transmission

- `POST /transmission/rpc`, JSON envelope `{"method":…, "arguments":…, "tag":…}`.
- **The `409` handshake applies to every request, forever** — the session id
  rotates hourly. Implement it inside the transport wrapper: on `409`, read
  `X-Transmission-Session-Id`, store it, resend once. Never surface a 409.
- Error ordering is fixed server-side and drives our mapping:
  `403` (IP not whitelisted / anti-brute-force lockout) → `.serverError` with a
  lockout hint; `401` (bad Basic auth) → `.auth`; `421` (DNS-rebinding host
  check, only when auth is off) → `.serverError` with the
  "add host to `rpc-host-whitelist` or connect by IP" hint.
- **HTTP 200 is returned even on failure** — branch on the `result` string
  (`"success"`), never on the status code alone.
- Per poll: `session-stats` (gives `downloadSpeed`, `uploadSpeed`,
  `torrentCount`, `activeTorrentCount` in one call) plus `torrent-get` with an
  explicit `fields` array (it is *required* in the old protocol):
  `id, name, status, percentDone, rateDownload, rateUpload, eta, error,
  errorString`. The per-torrent list feeds the dropdown only.
- Free space: `free-space` with `{"path": <download-dir>}` where `download-dir`
  comes from `session-get`. Uses `size-bytes` (2.80+, rpc 15+); `total_size`
  only exists on 4.0+. **Polled on a separate, slow cadence** (every 30 s or on
  first success) because the handler is a synchronous `statvfs` that can block on
  a hung NFS/SMB mount — it must never stall the speed poll.
- Protocol generation: the first unauthenticated POST doubles as a capability
  probe. Use the old camelCase protocol (works on 1.30–4.0.x, and 4.1+ still
  accepts it). Read `X-Transmission-Rpc-Version` when present and log it, so a
  future snake_case path can be added. **We do not implement the JSON-RPC 2.0
  snake_case path now** (YAGNI: the old protocol is accepted everywhere in the
  field, including every NAS package).
- `status` integers: 0 stopped, 1 queued-verify, 2 verifying, 3 queued-download,
  4 downloading, 5 queued-seed, 6 seeding.

### 4.3 Transport

A shared `HTTPTransport` that both clients use, so credential handling, TLS
policy, timeouts, and the Transmission 409 retry live in exactly one place.

- `URLSession` with `timeoutIntervalForRequest = 5s`, `timeoutIntervalForResource
  = 15s`, `waitsForConnectivity = false`, ephemeral config.
- `allowInsecureTLS` (per server) is implemented with a `URLSessionDelegate` that
  answers `urlSession(_:didReceive:completionHandler:)` with
  `URLCredential(trust:)` for server-trust challenges. This is opt-in per server
  and off by default.
- HTTP Basic auth via `URLCredential` in `didReceive challenge` for
  Transmission; the qBittorrent `SID` cookie is handled by a private
  `HTTPCookieStorage` on the ephemeral session.
- `ws://`-style host inputs are rejected during config validation; hosts are
  trimmed, and a host entered with a scheme or port is parsed rather than sent
  verbatim.

## 5. Polling and state

`MonitorStore` is a `@MainActor final class MonitorStore: ObservableObject`.

- One `Task` per enabled server, started/stopped as configuration changes,
  sleeping `interval` between polls. Because each server has its own task, a slow
  or hanging server cannot delay the others (R6).
- Interval is a single global setting (default 2 s, range 1–60 s) stored in
  `UserDefaults`.
- Results are written to `[UUID: ServerStatus]`; unchanged values are not
  re-published (avoids menu bar churn). The status item is updated only when the
  rendered string actually changes.
- Cancellation: tasks are cancelled and awaited on config change and on app
  termination.

## 6. Menu bar presentation

`StatusItemController` owns one `NSStatusItem`.

- Icon: a template SF Symbol reflecting worst-state among enabled servers
  (`arrow.down.circle` idle, `arrow.down.circle.fill` active,
  `exclamationmark.triangle` if every enabled server is failing).
- Text: `↓ 1.2M ↑ 340K`, rendered with `NSFont.monospacedDigitSystemFont` so
  digits do not jitter, and set via `attributedTitle` with
  `imagePosition = .imageLeft`.
- Width degradation (R5.2), in order: full form → compact form
  (`↓1.2M ↑340K`) → icon-only. Measured against the button's own width; the
  formatter is a pure function so AC14 is a unit test, not a visual check.
- Rate formatting: `B/s`, `K`, `M`, `G`, one decimal below 100, zero decimals
  above, so the string never grows unbounded.

The dropdown is the floating panel of §6.2 (Q5 revision, 2026-10-16); the
`NSMenu` sketch below is the historical record of the first implementation.

```
↓ 2.4M ↑ 680K   ·  7 active
─────────────────────────────
NAS-qBittorrent        connected       ↓ 1.2M ↑ 340K   4 active
NAS-Transmission       connected       ↓ 1.2M ↑ 340K   3 active
Old-NAS                auth failed
─────────────────────────────
Free space: 412 GB
Refresh Now                  ⌘R
Preferences…                 ⌘,
─────────────────────────────
Quit PT Monitor              ⌘Q
```

Error rows show the cause-specific hint text as the row's title. There is no
"Open Web UI" item: it would need a URL the API does not reliably report, and it
is not in R1–R11.

### 6.1 Torrent list embedded in the dropdown (R12, added 2026-10-16, revised same day)

No separate window (user revision, Q4): `MenuBuilder` adds one view-based
`NSMenuItem` whose `view` is an `NSHostingView` wrapping the SwiftUI
`TorrentListView`. `NSMenu` sizes the item to the view's frame and never resizes
dynamically, so the view gets a fixed frame (620×320) and the list scrolls
internally. The dropdown is rebuilt on every open (`menuNeedsUpdate`), so the
list is always fresh on open; live updates while it stays open rely on the
menu-tracking run loop servicing SwiftUI redraws (needs live verification —
worst case the data is simply as-of-open).

- **Placement.** Below the per-server rows and free-space line, above
  Refresh/Preferences/Quit. Not shown in the empty state (no servers → nothing
  to list; the empty state keeps "Add Server…").
- **Data source.** No new store: `MonitorStore.statuses` already publishes
  `ServerStatus.online(TransferSnapshot)` per server, and `TransferSnapshot`
  gains `torrents: [TorrentSummary]`. The view reads the store directly.
- **Layout / native look (revised 2026-10-16 after user feedback that the
  list looked like a white window).** No `SwiftUI.List` — it paints an opaque
  background over the menu's vibrancy material. The list is a transparent
  `ScrollView` + `VStack`, so the menu's own blurred material shows through.
  Section headers use small-caps semibold secondary text (the style macOS uses
  for grouped/sidebar headers); rows use the system font, semantic
  label/secondary colours, monospaced digits for live numbers, and `Divider`
  separators that pick up the menu's separator colour in light and dark mode.
  One section per enabled server: a header with the server display name plus
  its ↓/↑ speeds, then one row per torrent. Row: a small state indicator
  (SF Symbol + colour), truncated name, `ProgressView` bar, speed text via
  `ByteRateFormatter`, eta text (`—` when nil).
- **Ordering.** Fixed sort, no sort UI: downloading first, then seeding, then
  the rest, each group by down speed desc then name. Sorting stays in
  `TorrentSummary` as a pure static function so `--selftest` can check it.
- **Read-only.** No context menus, no buttons, no selection actions (R8).
  Clicks inside the view do not dismiss the menu; clicking outside does.
- **Rejected alternative:** the same list in a small `NSWindow` opened by a
  "Torrents…" item — implemented first, then replaced by the embedded menu
  item at the user's request. The window version needed explicit activation
  and was a second surface to manage; the embedded version needed neither.
  (The embedded-menu mechanism was itself superseded by §6.2's panel; the
  data source, ordering, read-only rule, and normalisation below carry over.)
- **Normalisation.**
  - qBittorrent `state` strings (research §1.3):
    `downloading`/`metaDL`/`forcedDL` → `downloading`; `stalledDL` → `stalled`;
    `queuedDL`/`queuedUP` → `queued`; `uploading`/`forcedUP`/`stalledUP` →
    `seeding`; `pausedDL`/`pausedUP` → `paused`; `checkingDL`/`checkingUP`/
    `checkingResumeData` → `checking`; `allocating`/`moving`/`unknown` →
    `other`; `error`/`missingFiles` → `error`.
  - qBittorrent `eta`: `8640000` (the API's "infinite" sentinel) or negative →
    `nil`.
  - Transmission `status` ints (research §2.2): 0 → `paused`; 1/2 →
    `checking`; 3/5 → `queued`; 4 → `downloading`; 6 → `seeding`; `error != 0`
    → `error` (overrides the status mapping).
  - Transmission `eta`: `-1`/`-2` → `nil`; `percentDone` is already 0…1.

### 6.2 CodexBar-style floating panel (Q5 revision, 2026-10-16 — current)

The user pointed at https://codexbar.app and asked for that look. A faithful
reproduction is impossible inside an `NSMenu` (macOS owns the menu's material,
corner radius, and item sizing), so the dropdown becomes a custom borderless
`NSPanel` anchored under the status item. The whole UI is one SwiftUI view;
the per-server sections, torrent-row content, ordering, and read-only rule of
§6.1 carry over unchanged.

**Anatomy** (CodexBar's popover mapped onto our data):

| CodexBar element | PT Monitor equivalent |
| --- | --- |
| Header: "Codex" / "Updated just now" + account/plan | "PT Monitor" / relative freshness ("Updated 2s ago") + "N servers · M online" |
| Session/Weekly pill meters | Per-torrent **progress meters** (styling below) |
| 2-column number grid (label over value) | **↓ speed / ↑ speed / active·total torrents / free space**, aggregated over online servers |
| 31-day bar chart | none — no history; torrent rows take the space |
| Credits footer | Per-server sections, then footer action rows |

Per-server section: small-caps header (display name + live ↓/↑ + state), then
torrent rows — state symbol, truncated name, pill progress meter, live
speeds, eta (`—` when nil) — in the §6.1 fixed sort. A failed server shows the
cause-specific hint (R6) as its section note; connecting shows "Connecting…".
Empty state (no servers): "No servers configured" plus an "Add Server…"
button that opens Preferences (AC4).

**Styling** (extracted from the site's CSS; adaptive light/dark — dark mode
matches the mockup):

- Card: ~16 pt corner radius, near-opaque dark gradient in dark mode
  (`#232326 → #141416` over a `NSVisualEffectView` blur), hairline 8%-white
  border, large soft shadow; light mode uses the equivalent light materials.
- Typography: system font, tight tracking, bold values (≥ `semibold`);
  secondary text at ~60% label opacity; monospaced digits for every live
  number. State colours/symbols stay as in §6.1.
- Meters: pill-shaped (`Capsule`), ~3 pt height, track at ~10% fill opacity,
  fill in the teal accent `#4fb6c3` — same shape as CodexBar's usage meters.
- Footer action rows: "Refresh Now", "Preferences…", "Quit PT Monitor" as
  full-width hover-highlighted rows. The ⌘R/⌘Q key equivalents are dropped —
  a borderless panel has no menu key-equivalent machinery.

**Window mechanics:**

- `NSPanel`, `.nonactivatingPanel`, borderless, `level = .statusBar`,
  `isOpaque = false`, clear background, `hasShadow = true`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. Rounded
  corners + border live in the SwiftUI content; the window shadow follows the
  content shape.
- Positioning: under the status item button frame (converted to screen
  coordinates); flip above the item if it would run off the screen bottom.
  Re-clicking the status item toggles the panel.
- Dismissal: global + local mouse-down monitors (click outside → close) plus
  Esc. The panel never activates the app, so keyboard focus stays where it
  was (AC18's behaviour is preserved).
- Live updates: `@ObservedObject MonitorStore` in a real window redraws on
  every publish — §6.1's menu-tracking caveat ("worst case rows are
  as-of-open") is gone.
- `MenuBuilder.swift` is deleted; its header/aggregate/error-row logic moves
  into the SwiftUI view. `StatusItemController` drops the `NSMenu` and gets a
  button target/action that shows the panel.

## 7. Persistence

- **`UserDefaults`** (`SettingsStore`): `servers` as a JSON `[ServerConfig]`,
  `pollInterval`, `showSpeedsInMenuBar`. Accessed through one small wrapper, not
  scattered `UserDefaults.standard` calls.
- **Keychain** (`KeychainStore`): `kSecClassGenericPassword`,
  `service = <bundle-id>.server`, `account = <server UUID>`. Passwords are only
  written when non-empty, and deleted when cleared or when the server is
  deleted. No access-control list is attached, so the default ACL applies.

  Known dev-loop tradeoff: an ad-hoc-signed `.app` gets a new code signature on
  every rebuild, so macOS may re-prompt for Keychain access after a rebuild. This
  is expected for unsigned local builds and disappears once the app is signed
  with a stable identity.

## 8. Bundle and build

`scripts/build-app.sh`:

1. `swift build -c release`
2. Assemble `build/PTMonitor.app/Contents/{MacOS,Resources}` + `PkgInfo`
3. Render `Resources/Info.plist` with the version and bundle id
4. `codesign --force --sign - build/PTMonitor.app` (ad-hoc)

`Info.plist` keys (from `research/apis.md` §3.2):

| Key | Value | Why |
| --- | --- | --- |
| `LSUIElement` | `YES` | Menu-bar-only; no Dock icon |
| `LSMinimumSystemVersion` | `12.0` | Deployment target |
| `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | `YES` | Not needed on macOS 12, required on macOS 14+ for raw-IP URLs. Do **not** use `NSAllowsArbitraryLoads`: it is ignored when this key is present |
| `NSLocalNetworkUsageDescription` | short string | Harmless on 12; required on macOS 15+ |
| `NSHighResolutionCapable` | `YES` | Crisp status item |
| `CFBundle{Identifier,Executable,Name,PackageType,ShortVersionString,Version}` | — | Required for a hand-assembled bundle to launch as an agent |

Not needed: `NSBonjourServices`, the multicast entitlement, and all sandbox
entitlements (the app is unsandboxed — a SwiftPM build with no
`com.apple.security.app-sandbox` entitlement is not sandboxed).

## 9. Build/run shape

- `swift build` / `swift run PTMonitor --selftest` for the loop. **Not**
  `swift test` — XCTest is absent under CLT.
- `./scripts/build-app.sh && open build/PTMonitor.app` for the real thing.
- Host architecture only (this is an Intel Mac). Universal binaries would need
  cross-arch SDK work that CLT alone makes unreliable; deferred and documented.
- `main.swift` inspects `CommandLine.arguments` first: `--selftest` runs the
  in-binary checks and exits with 0/1; `--probe ...` runs `ProbeRunner` and
  exits; otherwise bootstrap `NSApplication` with
  `setActivationPolicy(.accessory)` + the `AppDelegate`.

## 10. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Cannot verify against a real server from here | `--probe` mode (R11) + recorded-response unit tests; live AC5–AC8/AC10 executed by the user against the NAS |
| qBittorrent version drift in optional fields | Optional decoding keys + cached `webapiVersion` gate |
| Transmission session-id rotation | 409 retry implemented in the transport, exercised on every request |
| `free-space` blocking on a hung NAS mount | Separate slow cadence + 5 s timeout + treated as optional |
| Keychain re-prompts after each ad-hoc rebuild | Documented as expected for unsigned local builds |
| Self-signed HTTPS on a NAS | Per-server `allowInsecureTLS`, off by default |
| Menu bar text jitter/overflow | Monospaced digits + pure-function degradation ladder, covered by `--selftest` |
| `swift test` unavailable under CLT | In-binary `--selftest` with the same non-zero-exit contract; `PTMonitorCore` stays a library target so XCTest can be added if Xcode is installed later |

## 11. Extension path (explicitly deferred)

Control actions arrive later without restructuring: add
`func pauseAll() async throws`, `resumeAll()`, `addTorrent(magnet:)` to
`TorrentClient`, have each client implement its endpoint
(`/api/v2/torrents/{pause,resume,add}` and `torrent-start`/`torrent-stop`/
`torrent-add`), and surface menu items that call through `MonitorStore`. The
read-only design does not foreclose any of it.
