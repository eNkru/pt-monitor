# App Conventions (PTMonitor)

## 1. Scope / Trigger

Applies to every change in `Sources/`. These are the contracts that keep the
two remote APIs, the domain model, and the menu bar consistent. Changing any
signature here is a cross-layer change — update this file and the `--selftest`
checks together.

## 2. Module boundaries

- `PTMonitorCore` — models, clients, stores, diagnostics. **No AppKit/SwiftUI**
  except `ByteRateFormatter`'s use of `CoreGraphics`/`NSFont` width measurement.
  Everything here is usable from `--selftest` and `--probe`.
- `PTMonitor` — a thin executable: argv dispatch in `main.swift`, plus AppKit
  (`NSStatusItem`, the dropdown's borderless `NSPanel`, `NSApplication`) and
  SwiftUI views hosted in `NSWindow`/`NSHostingView`.
- `PTMonitorCore/Client` owns all networking; nothing else creates a
  `URLSession`.

## 3. Domain model (single owner)

Both APIs normalise into `TransferSnapshot`; nothing above the client layer
branches on `ServerKind`.

```swift
enum ServerKind: String, Codable { case qbittorrent, transmission }

struct ServerConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID; var kind: ServerKind; var name: String
    var host: String; var port: Int; var useTLS: Bool
    var allowInsecureTLS: Bool; var username: String; var isEnabled: Bool
}   // NOTE: no password field, ever (R4)

enum ServerStatus: Equatable {
    case disabled, connecting
    case online(TransferSnapshot)
    case failed(ServerFailure)
}

enum ServerFailure: Equatable {
    case unreachable(String), auth(String)
    case banned(String)
    case protocolViolation(String), serverError(String)
}   // ServerFailure conforms to Error so clients throw it directly
```

`banned` means "the server is refusing this client for now" (qBittorrent's IP
ban, Transmission's lockout / `rpc-whitelist` rejection). It exists as its own
case because it must back off far harder than anything else.

### Per-torrent summaries (R12)

`TransferSnapshot.torrents: [TorrentSummary]` carries the per-torrent list to
the UI. The normalisation tables live **only** in the two parsers — one
owner, asserted in `--selftest` (AC17):

- qBittorrent `state` strings → `TorrentState` (e.g. `stalledUP → .seeding`,
  `checkingResumeData → .checking`, unknown values → `.other`);
- Transmission `status` ints → `TorrentState` (0 paused, 1/2 checking, 3/5
  queued, 4 downloading, 6 seeding), with `error != 0` **overriding** the
  status mapping;
- eta sentinels → `nil` (qBittorrent `8640000` or negative; Transmission
  `-1`/`-2`); the UI renders `nil` as an em dash, never a bogus number;
- `progress` clamped to 0…1;
- the fixed display sort is `TorrentSummary.sorted` (downloading → seeding →
  rest, each by down speed desc then name) — a pure static function so
  `--selftest` covers it and neither client drifts.

Rule: parse each API payload **once**, in a pure `…Parser`, into the domain
model. The UI never re-reads raw JSON fields.

## 4. API client contracts

```swift
protocol TorrentClient: Sendable {
    func fetchSnapshot() async throws -> TransferSnapshot
    func testConnection() async throws -> String   // version string
}
```

### 4.1 qBittorrent (WebUI API v2)

- `POST /api/v2/auth/login`, form-encoded `username=&password=`, **no `Origin`,
  no `Referer`** (CSRF is on by default and only skipped when both are absent).
- **The login verdict moved from the body to the status code in qBittorrent
  5.2** (`src/webui/api/authcontroller.cpp`):

  | server | success | wrong credentials | banned IP |
  | --- | --- | --- | --- |
  | ≤ 5.1 | `200 "Ok."` | `200 "Fails."` | `403` |
  | 5.2+ | `204`, no body | `401 "Unauthorized"` | `403` |

  Accept **all** of them: `204` success, `200 "Ok."` success, `200 "Fails."`
  → `.auth`, `401` → `.auth`, `403` → `.banned`. `Ok.` is not proof of
  credentials (localhost/subnet bypass). A `200` with a blank body stays a
  `.protocolViolation`. Reading only the ≤ 5.1 shape made every login against
  a 5.2 server fail with "login failed with HTTP 204" while the `SID` cookie
  had in fact been set; `scripts/fake-qbittorrent.py` reproduces both
  generations (`WEBAPI=5.2`).
- `204` from `auth/login` is a **body-less success**: never treat an empty body
  as a protocol violation on that endpoint, and never gate the login on the
  WebAPI version (a 204 is self-describing).
- **The `SID` cookie must be carried by the session's own storage.** Do **not**
  assign a hand-made `HTTPCookieStorage()` to
  `URLSessionConfiguration.httpCookieStorage`: on macOS 12.7.6 the session then
  silently stores nothing and never replays the cookie, so every request after
  login arrives sessionless (see §9). `URLSessionConfiguration.ephemeral`
  already provides a private per-session store that never leaks to
  `HTTPCookieStorage.shared` — that is what to rely on.
- Poll `GET /api/v2/sync/maindata?rid=0` every time (full snapshot; no `rid`
  deltas). Do not use `/transfer/info`.
- `free_space_on_disk` only when cached `webapiVersion >= 2.1.1`; otherwise
  `nil`. Reject WebAPI `< 2.0` up front.
- Active count derives from the normalised states (`.downloading`, `.seeding`,
  `.stalled`) — exactly the old wire-state set {`downloading`, `metaDL`,
  `forcedDL`, `uploading`, `forcedUP`, `stalledDL`, `stalledUP`}; total =
  count of the `torrents` map.
- A `401` **or `403`** from a non-login endpoint → re-login once, retry once,
  then fail. Never loop.
- **`403` means two completely different things — never conflate them.**
  - `403` from `auth/login` → `.banned`. The ban is the *only* `AccessDenied`
    that endpoint can throw (the server checks the ban before the credentials).
  - `403` from any other endpoint → **not a ban**. `webapplication.cpp` answers
    *any* private API call made without a session with `403`
    (`!session() && !isPublicAPI` → `ForbiddenHTTPError`), so this means the
    session cookie was not accepted → `.protocolViolation`.

  A bug that mapped both to "the server banned this IP" sent a broken cookie
  jar out as a server ban and cost a long debugging detour. `ServerFailure`
  cases are asserted separately in `--selftest` to keep them apart.

### 4.2 Transmission (RPC)

- `POST /transmission/rpc`, JSON `{"method":…,"arguments":…,"tag":…}`.
- **409 handshake on every request, forever** — the session id rotates hourly.
  The transport (`SessionIdHandshake`) reads `X-Transmission-Session-Id`,
  stores it, and resends the exact request once. A 409 is never surfaced.
- **Branch on the `result` string (`"success"`)**, never on the HTTP status:
  Transmission returns 200 even on failure.
- Status mapping: `401` → `.auth`; `403` → `.serverError` (whitelist /
  anti-brute-force lockout); `421` → `.serverError` (add host to
  `rpc-host-whitelist` or connect by IP).
- Old camelCase protocol only. Per poll: `session-stats` (+ `torrent-get` with
  an explicit `fields` array). `free-space` runs on a **separate ~30 s cadence**
  using `download-dir` from `session-get`; it is optional and must never stall
  the speed poll.
- **Requests carry a proactive `Authorization: Basic …` header** (set on every
  attempt inside the 409-handshake closure; credentials never logged).
  Reason: with the async `URLSession.data(for:)` API the session-level
  `didReceive`-challenge callback is not reliably invoked on recent macOS
  (reproduced on macOS 26 — the Basic-auth challenge never fired). `401` still
  maps to `.auth` exactly as before; the header only changes *how* credentials
  reach the server, not the failure semantics.

### 4.3 Transport

One `HTTPTransport` owns timeouts (5 s request / 15 s resource),
`waitsForConnectivity = false`, the ephemeral cookie storage, the opt-in
self-signed-trust delegate, and the 409 retry hook.

Auth is split by client: qBittorrent uses its form login (the `SID` cookie);
Transmission sets the `Authorization: Basic` header itself (§4.2). The
delegate challenge path (`TransportSessionDelegate`) implements **both** the
session-level and the task-level `didReceive` hooks — when both exist,
URLSession calls only the task-level one, so the task-level method forwards to
the single session-level implementation. That keeps the self-signed TLS
opt-in working on macOS versions where the session-level callback is not
reliably invoked for the async data-task API (the same quirk that forced the
proactive Basic-auth header). Do not delete the task-level forwarder as
"redundant" — it is the load-bearing one on current macOS.

## 5. Polling and state

- `MonitorStore` is `@MainActor final class … : ObservableObject`.
- **One task per enabled server.** A slow/hanging server must never delay the
  others (R6). Disabled servers are never contacted (R3/AC12).
- Publish only when a status actually changes (ignore `fetchedAt`) to avoid
  menu-bar churn.
- **Credential-failure backoff is mandatory.** qBittorrent bans an IP once
  `WebUI/MaxAuthenticationFailCount` logins have failed (default **5**) and
  counts every failed attempt until a login *succeeds* — the counter is **not
  time-limited** (`authcontroller.cpp::increaseFailedAttempts`), and the ban
  lasts `WebUI/BanDuration` (default **3600 s**). A 2 s poll timer therefore
  turns one typo into a one-hour ban. `MonitorStore.retryDelay` spaces retries
  at `credentialFailureBackoff` (600 s) for `.auth` and `bannedBackoff` (900 s)
  for `.banned`, never shortening a longer user-configured interval. Editing the
  server (which calls `reconcile`) or "Refresh Now" retries immediately.
- Inject the client factory and the sleep so checks never hit the network or
  wait on real time.

## 6. Persistence

- `UserDefaults` (via `SettingsStore` only): `servers` as JSON `[ServerConfig]`,
  `pollInterval` (default 2, clamp 1–60), `showSpeedsInMenuBar`,
  `showActiveTorrentsOnly` (default `false`, display-only — changing it never
  rebuilds pollers).
- Passwords live **only** in the Keychain (`KeychainStore`,
  `kSecClassGenericPassword`, `service = <bundle-id>.server`,
  `account = <server UUID>`). Write only when non-empty; delete on clear or
  server delete. Never place a password in `ServerConfig` or defaults (R4/AC9).
- **Write the Keychain password before saving the configuration**, and surface a
  Keychain failure in the editor instead of swallowing it. A server that is
  enabled while its password never reached the Keychain polls with an empty
  password, fails every login, and gets the Mac's IP banned.

## 7. Menu bar + dropdown panel (macOS 12 — no `MenuBarExtra`)

- `NSStatusItem` with a **template** SF Symbol so it adapts to light/dark/
  highlighted bars: `arrow.down.circle` idle, `arrow.down.circle.fill` active,
  `exclamationmark.triangle` when every enabled server is failing.
- Speed text via `attributedTitle` using
  `NSFont.monospacedDigitSystemFont` (no digit jitter); `imagePosition =
  .imageLeft`.
- Width degradation is a pure function:
  `ByteRateFormatter.degradedSpeedText(down:up:availableWidth:measure:)`
  returns full → compact → `nil` (icon-only). It must never truncate
  mid-number (R5.2/AC14).
- `showSpeedsInMenuBar == false` → icon only; the icon still reflects state.
- The dropdown is a **custom borderless `NSPanel`** (`PanelController` /
  `PanelView`), not an `NSMenu`: a menu cannot render custom chrome (rounded
  card, gradient, hover-highlighted footer rows) and a real window keeps
  SwiftUI updating live while open. Panel contract:
  - `.nonactivatingPanel`, borderless, `level = .statusBar`, `isOpaque =
    false`, clear background, `hasShadow = true`, `hidesOnDeactivate =
    false` (the app is `.accessory` and may never be frontmost),
    `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
  - The panel subclass answers `canBecomeKey = true` so it can take Esc via
    `cancelOperation` **without activating the app** (AC18).
  - Positioning: under the status item's screen frame, flipped above the item
    if it would run off the screen bottom; height from the SwiftUI content's
    fitting size, capped at ~70% of the screen.
  - **The anchor frame is captured once per presentation** (`show()`), never
    recomputed by a relayout. The item is `variableLength`, so its width —
    and `midX` — changes with the speed text (`999 B/s` vs `1.2M`, or a
    full → compact degradation step); re-deriving the anchor on every poll
    publish slid the open panel sideways. Relayouts (content height changes)
    keep the top edge pinned and `midX` fixed, and skip the `setFrame` write
    when the computed rect equals the current frame so an idle panel is not
    repositioned/redisplayed every 2 s.
  - Dismissal: global + local mouse-down monitors (click outside), Esc, and
    re-clicking the status item toggles. The local monitor must **exclude
    the status item's frame** or the toggle fights the close. Monitors are
    removed on every `hide()` and in `deinit` (`MainActor.assumeIsolated`
    under Swift 6).
  - Content: header + freshness, aggregate 2-column grid, per-server sections
    (torrent rows: state dot, 2-line name, full-width progress bar with a
    monospaced percentage, one detail line; cause-specific failure hints, R6;
    empty state with "Add Server…", AC4), footer action rows (Refresh
    Now / Preferences… / Quit). Key equivalents (⌘R/⌘Q) are dropped — a
    borderless panel has no menu key-equivalent machinery.
- **Hosting-view lifecycle (performance contract).** The panel's
  `NSHostingView` is built **fresh on every `show()`** and destroyed on every
  `hide()` (`panel.contentView = nil`, reference dropped). Never keep a
  hosting view attached to an ordered-out panel: it keeps running its layout
  feedback loop at display-frame rate even while hidden, which — combined
  with an eager list — pinned the main thread at 60–99% CPU with the dropdown
  closed (fixed 2026-10-18; 76% → 3.7% at 1500+800 stub rows). Scroll
  position resets between opens by design ("fresh on every open").
- **Torrent list rendering is bounded and lazy**: `LazyVStack` (never a plain
  `VStack` — it materialises every row) inside the `ScrollView`, and at most
  `PanelView.maxVisibleTorrentsPerServer` (100) rows per server in the
  clients' fixed sort order, followed by a localized "+ N more torrents"
  footnote (plain text — no "show all" action, R8).
- **Opt-in active-only filter** (`showActiveTorrentsOnly`): rows are filtered
  to `TorrentSummary.isActive` (down/up speed > 0, pure + `--selftest`-covered)
  **before** the 100-row cap; the footnote counts the filtered array. With the
  filter on, a non-empty library with nothing transferring shows the localized
  "No active torrents." note (vs "No torrents." for an actually empty
  library). The aggregate grid's server-reported counts are unaffected.
- **Torrent row anatomy** (redesigned 2026-10-18): a state dot + name
  (`lineLimit(2)`, tail truncation), a full-row-width capsule progress bar
  (7pt, filled with `PanelView.color(for:)`) with a monospaced percentage at
  its right end, and one detail line. **Which** detail segments a row shows is
  decided by `TorrentSummary.infoSegments(state:down:up:etaSeconds:)` — a pure
  function returning `[TorrentRowInfoSegment]` (`down`/`up`/`eta`/`stateWord`)
  with **no strings**, so `--selftest` can assert it; the app target turns
  segments into localized text (`L10n.stateWord`, `L10n.eta`). Rules it
  encodes: a zero rate is omitted rather than rendered as a bare arrow, **both**
  directions are shown when both are moving (a torrent can seed while it
  downloads — dropping its upload rate hides real traffic), and a row with
  nothing else to say falls back to its state word — never an em dash.
  Keep new row formatting decisions in that helper, not in the view, or they
  become untestable. A full-width bar whose fill is proportional must not add a
  `GeometryReader` per row; scale the fill from the leading edge and clip to the
  capsule.
- **Read-only**: no pause/resume/add/remove. No control endpoints; torrent
  rows and sections carry no actions (R8, AC18). Only footer rows act.

## 8. Tests required

- Pure logic (formatter, parsers, host parsing, retry decisions) → a
  `--selftest` check with an explicit expected value.
- A parser/decoder change must update its recorded fixture **and** the
  assertion that reads it.
- `Sendable`/`@MainActor` correctness: clients are actors, `MonitorStore` is
  `@MainActor`; verify with a warning-free `rm -rf .build && swift build`.

## 9. Wrong vs Correct

#### Wrong — a hand-made cookie storage silently breaks qBittorrent sessions

```swift
let configuration = URLSessionConfiguration.ephemeral
// Stores nothing on macOS 12.7.6: login succeeds, the SID is dropped, and every
// follow-up request arrives sessionless -> qBittorrent answers 403, which reads
// like "your IP was banned" but is not.
configuration.httpCookieStorage = HTTPCookieStorage()
```

#### Correct — let the ephemeral session keep its own private store

```swift
let configuration = URLSessionConfiguration.ephemeral   // private cookie store
configuration.httpShouldSetCookies = true
configuration.httpCookieAcceptPolicy = .always
```

Verify with a stub WebUI, not by reading the code — the failure is invisible to
any network-free check (`scripts/fake-qbittorrent.py`, see
`build-and-run.md` §7).

#### Wrong — control endpoint and password in defaults

```swift
// R8 violation: the app is read-only.
try await client.pauseAll()
// R4/AC9 violation: credentials must never be persisted here.
defaults.set(config.password, forKey: "password-\(config.id)")
```

#### Correct — read-only polling + Keychain

```swift
let snapshot = try await client.fetchSnapshot()   // observe only
try keychain.setPassword(password, for: config.id)
```

## 10. Localization (R9: English + Simplified Chinese)

Two mechanisms, decided by where the string lives:

- **SwiftUI string literals** (`Text/Button/Toggle/TextField/Picker/SecureField`
  titles, `.help()` tooltips) are already `LocalizedStringKey` — they localize
  purely through `Localizable.strings`, no code changes. A `Text(someString)`
  with a **variable** does NOT localize; if a dynamic string must localize, it
  goes through `L10n` (or the param type becomes `LocalizedStringKey`, as in
  `PanelView.stat(label:)` and `FooterRow.title`).
- **Code-built strings** go through `App/L10n.swift` +
  `NSLocalizedString`. **The key IS the English text** — a bundle without a
  matching `.lproj` falls back to exactly the old English, which keeps raw
  binary runs (`--probe`, `--selftest`) English forever.

Hard rules:

- **`--selftest`/`--probe` output and `ServerFailure.message` technical detail
  stay English, always.** No selftest assertion may depend on a localizable
  string (the check: forced `-AppleLanguages (zh-Hans)` selftest must pass).
  UI failure notes render a localized cause headline (`L10n.causeHeadline`)
  with the English detail beneath it — diagnostics stay greppable (R6).
- **Proper names** ("PT Monitor", "qBittorrent", "Transmission") are
  deliberately absent from the tables; missing-key fallback renders them
  verbatim in every language.
- **Parity is a build gate**: `scripts/check-localization.py` (runs inside
  `build-app.sh`, before codesign) fails the build unless every
  `Resources/*.lproj/Localizable.strings` carries the same key set. Adding a
  UI string means adding it to **both** tables in the same change.
- `CFBundleLocalizations` = `[en, zh-Hans]`; the bundle script copies every
  `Resources/*.lproj` into `Contents/Resources`.

#### Wrong — a new UI string with no table entry

```swift
Text("Delete Server")            // English forever; zh users see English
// and nothing in scripts/check-localization.py catches it (the tables
// only know the keys that already exist).
```

#### Correct — add the key to every language in the same change

```swift
Text("Delete Server")
// en.lproj:   "Delete Server" = "Delete Server";
// zh-Hans.lproj: "Delete Server" = "删除服务器";
```
