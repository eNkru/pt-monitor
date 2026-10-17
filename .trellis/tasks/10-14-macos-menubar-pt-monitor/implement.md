# Implementation Plan — macOS Menu Bar PT Monitor

Ordered checklist. Each step is verifiable before the next one starts; the build
must stay green at every step.

## Validation commands

```bash
swift build                     # must succeed with Command Line Tools only
swift run PTMonitor --selftest  # in-binary checks (XCTest is unavailable with CLT)
./scripts/build-app.sh          # assembles build/PTMonitor.app
open build/PTMonitor.app        # manual: status item appears, no Dock icon
build/PTMonitor.app/Contents/MacOS/PTMonitor --probe ...   # headless API check
```

`swift test` is **not** usable: Command Line Tools has no `XCTest.framework`, so
any `testTarget` fails with `error: XCTest not available`. Do not add a `Tests/`
target. Automated checks go in `Diagnose/SelfTest.swift` and run through
`--selftest`.

Live NAS checks (AC5–AC8, AC10) need the user's host, port, and credentials.

## Steps

1. **Scaffold the package.**
   `Package.swift` (`swift-tools-version:5.7`, `platforms: [.macOS(.v12)]`,
   library `PTMonitorCore` + executable `PTMonitor`; **no test target**),
   directory skeleton from `design.md` §2, and a `main.swift` that prints a
   version and exits. **Verify:** `swift build`.
2. **Domain model.** `ServerConfig`, `TransferSnapshot`, `ServerStatus`,
   `ServerFailure`, `ServerKind`. Pure values, `Codable` + `Equatable`.
   **Verify:** `swift build`.
3. **Byte-rate formatter + self-test harness.** `ByteRateFormatter` with
   full/compact forms and the degradation ladder, plus the minimal
   `SelfTest` harness (check/expect helpers, non-zero exit on first failure).
   **Verify:** `swift run PTMonitor --selftest` for `0`, `999 B/s`, `1.0 KB/s`,
   `1.2 MB/s`, `1.00 GB/s`, the compact form, and the over-wide → shorter → nil
   ladder (covers AC14).
4. **Transport.** `HTTPTransport`: ephemeral `URLSession`, timeouts, Basic auth,
   cookie storage, optional self-signed trust delegate, plus the generic
   `409 → capture header → retry once` hook used by Transmission.
   **Verify:** `swift build`.
5. **qBittorrent client.** Login (no `Origin`/`Referer`, `Fails.` → `.auth`),
   `sync/maindata?rid=0` parse, `webapiVersion` gate for `free_space_on_disk`,
   active/total torrent counts, 401 → re-login once → retry once.
   **Verify:** `--selftest` checks against a recorded `maindata` fixture and the
   `200 "Fails."` credential case.
6. **Transmission client.** 409 handshake, `session-stats`, `torrent-get` with
   explicit `fields`, `session-get` for `download-dir`, `free-space` on the slow
   cadence, `result != "success"` handling, and the 401/403/421 → failure-cause
   mapping. **Verify:** `--selftest` checks against a recorded `session-stats`
   fixture and a 409-then-retry transport check.
7. **Keychain store.** Read/write/delete generic passwords keyed by server UUID.
   **Verify:** `swift build`; runtime check under AC9.
8. **Settings store.** `UserDefaults` wrapper for the server list, poll interval,
   and show-speeds toggle. **Verify:** `swift build`.
9. **Monitor store.** Per-server poll tasks, cancellation, interval handling,
   change-only publishing. **Verify:** `swift build`; behaviour under AC12.
10. **Headless diagnose modes.** `ProbeRunner` + `SelfTest` + argv dispatch in
    `main.swift`, JSON output from `--probe`, non-zero exit with a readable
    message on failure, no GUI either way. **Verify:** `--selftest` green, plus
    AC13 against a bogus host (error path) — the probe happy path needs the NAS.
11. **Status item + menu.** `StatusItemController`, `AppDelegate` (accessory
    policy, no window at launch), `MenuBuilder` for the dropdown including the
    empty state, per-server rows, error hints, Refresh/Preferences/Quit.
    **Verify:** `open build/PTMonitor.app`, AC2/AC4/AC11/AC15.
12. **Preferences UI.** SwiftUI `PreferencesView` + `ServerEditorView` in an
    `NSWindow`/`NSHostingView` window controller, with Test Connection and
    validation. **Verify:** AC5/AC6/AC7/AC12 manually.
13. **Bundle script + Info.plist.** `scripts/build-app.sh` and
    `Resources/Info.plist` per `design.md` §8. **Verify:** AC1, AC2, AC9.
14. **Full pass.** Run every automated check, then the live NAS checks with the
    user. Record results per acceptance criterion.
15. **Torrent list window (R12, added 2026-10-16).**
    15a. `Model/TorrentSummary.swift`: `TorrentState` + `TorrentSummary` + the
         fixed-sort static function; `TransferSnapshot` gains
         `torrents: [TorrentSummary]` (default `[]`).
    15b. qBittorrent parser: map the `torrents` map it already walks into
         summaries (state table + eta `8640000`/negative → nil).
    15c. Transmission parser: parse the `torrent-get` reply it already fetches
         and currently discards (status ints, `percentDone`, eta `-1`/`-2` →
         nil, `error != 0` → `error`).
    15d. `MenuBuilder` embeds `TorrentListView` in a view-based `NSMenuItem`
         (620×320 `NSHostingView`); no separate window and no "Torrents…" item
         (user revision Q4: list lives in the dropdown).
    15e. `SelfTest` additions: state-mapping tables for both clients, eta
         sentinels, progress clamping, sort order (AC17).
    **Verify:** `swift build`, `swift run PTMonitor --selftest` green
    (AC17), then manual: the dropdown embeds the list below the server rows,
    rows are fresh on open and update while open, clicking outside dismisses
    (AC16, AC18); live rows need the NAS.
16. **CodexBar-style floating panel (Q5, 2026-10-16).** Replaces the `NSMenu`
    dropdown with the panel of design §6.2.
    16a. `App/PanelController.swift`: borderless `NSPanel` + positioning
         under the status item, screen-edge flip, global/local click-outside
         + Esc dismissal, show/toggle from `StatusItemController`'s button
         action (drop the `NSMenu`, `NSMenuDelegate`, `menuNeedsUpdate`).
    16b. `App/PanelView.swift`: the whole dropdown as SwiftUI — header
         ("PT Monitor" + relative freshness + server count), aggregate
         number grid (↓/↑/active·total/free space), per-server sections
         (header + torrent rows with pill progress meters) reusing
         `TorrentListView`'s row logic, footer action rows
         (Refresh / Preferences / Quit), empty state with "Add Server…".
         CodexBar styling per design §6.2; absorb `MenuBuilder`'s
         header/aggregate/error-row logic and delete `MenuBuilder.swift`.
    16c. `--selftest`: any pure helpers that moved (aggregate/free-space
         pick) stay covered; no new fixtures needed.
    **Verify:** `swift build` 0 warnings, `--selftest` green,
    `./scripts/build-app.sh` green; manual: click status item → styled panel
    appears anchored under it, click-outside/Esc/re-click dismisses, rows
    update live while open (AC16/AC18 with Q5 wording).

## Risk / rollback points

- **Step 5–6 (API clients)** are the highest-risk work; the recorded fixtures
  in `Diagnose/SelfTest.swift` are what make them independently checkable. If a
  fixture-based assumption proves wrong against the NAS, the fix is local to one
  client file.
- **Step 13 (bundle)** is the step most likely to fail on a CLT-only machine.
  Fallback if `codesign` or bundle assembly misbehaves: run the raw
  `swift build` binary directly to confirm app logic, and fix packaging
  separately. This does not block steps 1–12.
- No migrations, no persisted schema that predates this work, no deployment: the
  only rollback is deleting `build/` and `~/Library/Preferences/<bundle-id>.plist`
  and the Keychain items.

## Deferred (not in this task)

Control actions, launch at login, per-server intervals, notifications, universal
binary, signing/notarization. See `prd.md` → Out of Scope and `design.md` §11.

---

## Progress (2026-10-14)

- Steps 1–13 implemented; step 14's automated checks pass.
- `swift build` clean (0 warnings), `swift run PTMonitor --selftest` = **113
  checks passed**, `./scripts/build-app.sh` produces an ad-hoc-signed
  `build/PTMonitor.app`; `--probe` error paths exit non-zero with a readable
  message and no GUI.
- Local (non-live) ACs confirmed: **AC1, AC3, AC12, AC14**. App launches as a
  background agent with no Dock icon/window (AC2 non-visual part).
- Quality check fixed one High issue: credential-failure backoff
  (`MonitorStore.retryDelay`, 30 s) to avoid tripping server anti-brute-force
  bans on a wrong password.
- **Environment caveat**: the installed Command Line Tools (14.2) is missing
  `usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftinterface`, which breaks
  every `swift build`. Workaround + regeneration recipe documented in
  `.trellis/spec/macos/build-and-run.md`. Permanent fix: reinstall CLT or
  install Xcode.
- **Pending user/live verification** (needs the NAS or GUI): AC2 (visual), AC4,
  AC5–AC8, AC9 (runtime `defaults`/Keychain), AC10, AC11, AC13 happy path,
  AC15. The task stays `in_progress` until these are confirmed.

## Environment restoration + macOS 14 round (2026-10-16)

The dev machine was upgraded macOS 12.7.6 → **14.8.9 (Sonoma)**, which wiped the
old CLT 14.2 install. Reinstalled **CLT 16.2 (Swift 6.0.3)** via the
`softwareupdate` in-progress trick; removed the now-obsolete
`~/.local/bin/swift` shim (its stale 14.2 overlay caused
`mismatched PackageDescription` on every build). Details recorded in
`.trellis/spec/macos/build-and-run.md` §4.

- `swift build` clean (**0 warnings**; three `static let` on `@MainActor`
  constants needed `nonisolated` under Swift 6.0.3), `--selftest` **127 checks**
  (was 121), `./scripts/build-app.sh` green, ad-hoc signature valid.
- **macOS 14 ATS verified empirically**: with `NSAllowsLocalNetworking=YES`,
  loopback and RFC1918 LAN IPs work untouched (the NAS case); public-range IPs
  and public FQDNs over plain HTTP are blocked. `HTTPTransport.describe` now
  maps that block to a cause-specific hint (LAN address or HTTPS) — R6 polish —
  with 6 new selftest checks. Stub round-trip re-run after the transport edit:
  happy path + `auth failed` both correct, no sessionless 403.
- App launches on macOS 14 (agent, no Dock icon) — re-confirmed below when the
  user runs the GUI checks.
- **Still pending live verification**: AC2 (visual), AC4–AC11, AC13 happy path,
  AC15 — need the user's NAS reachability/credentials and manual GUI checks.

## Torrent list round (R12, 2026-10-16)

- Step 15 implemented: `TorrentSummary` model + both clients' normalisation
  (qBittorrent `state` strings, Transmission `status` ints, eta sentinels,
  progress clamping, `error != 0` override), and `--probe` output now includes
  the normalised `torrents` array (useful for live NAS verification without
  the GUI).
- **Presentation revised same day (Q4)**: the list was first built as a
  separate window opened by a "Torrents…" item; the user asked to embed it in
  the dropdown instead. It is now a view-based `NSMenuItem` (620×320
  `NSHostingView` wrapping `TorrentListView`) placed below the server rows;
  `TorrentListWindowController` and the "Torrents…" item were removed, and
  the `onTorrents` plumbing reverted.
- **Presentation revised again same day**: user feedback — the embedded list
  looked like a white window on the otherwise native menu. Cause:
  `SwiftUI.List` paints an opaque background over the menu's vibrancy
  material. Fix: transparent `ScrollView` + `VStack` with native styling
  (small-caps section headers, system font rows, `Divider` separators,
  semantic colours, monospaced digits). Design §6.1 Layout bullet records
  the decision.
- Gates after the revision: `swift build` 0 warnings, `--selftest` **185
  checks** (+58 for AC17), `./scripts/build-app.sh` green, probe error path
  exits 1 with a readable message, and a stub round-trip
  (`scripts/fake-qbittorrent.py`) shows the full login → maindata →
  torrents-JSON chain.
- **Pending live verification**: AC16 (visual: list embedded in the dropdown,
  fresh on open, updates while open — the menu-tracking run loop servicing
  SwiftUI redraws is the one uncertain part; worst case rows are as-of-open),
  AC18 (read-only, click-outside dismisses). Live rows need the NAS.

## CodexBar-style floating panel round (Q5, 2026-10-16)

- Step 16 implemented: the `NSMenu` dropdown is **replaced** by a custom
  borderless `NSPanel` (`App/PanelController.swift`) hosting one SwiftUI view
  (`App/PanelView.swift`) — header with relative freshness, aggregate 2-column
  number grid (↓/↑/active·total/free space), per-server sections with torrent
  rows and pill progress meters, footer action rows (Refresh / Preferences… /
  Quit), and the AC4 empty state with "Add Server…". `MenuBuilder.swift` is
  deleted; its header/aggregate/error-row logic moved into `PanelView`.
  `StatusItemController` drops the menu and toggles the panel from the button
  action. Key equivalents (⌘R/⌘Q) are gone — a borderless panel has no menu
  key-equivalent machinery.
- Because the panel is a real window, the menu-tracking caveat of the previous
  round ("worst case rows are as-of-open") is gone: rows redraw on every
  `MonitorStore` publish while open.
- 16c: no new fixtures needed — the aggregate helper selftest coverage carried
  over; the free-space `min()` rule moved verbatim from `MenuBuilder`.
- Gates: `swift build` 0 warnings, `--selftest` **185 checks**,
  `./scripts/build-app.sh` green (ad-hoc signed), probe error path exit 1 with
  a readable message. `trellis-check` pass: no High/Medium findings; only
  stale "list window" doc comments (Q4 wording surviving into the Q5 round)
  were fixed in `TorrentSummary`/`TransferSnapshot`/both clients.
- Spec updated: `.trellis/spec/macos/app-conventions.md` §2/§3/§4.1/§7 now
  describe the panel contract and the per-torrent normalisation owner.
- **Pending live verification** (manual, needs GUI): AC2 visual, AC4, AC16
  (styled panel anchored under the item, fresh + live rows), AC18 (read-only,
  click-outside/Esc/re-click dismissal). Live torrent rows need the NAS.

## App icon (2026-10-17)

- `scripts/make-icon.swift` draws the icon with pure CoreGraphics (no Xcode/asset
  catalog, R10) and feeds `iconutil` to produce `Resources/AppIcon.icns`.
  Identity: the panel's dark card + hairline border, solid-teal ↓ arrow with a
  dimmed ↑ arrow, and the teal pill meter at 62% — every icns size is rendered
  crisp from the vector shape, never downscaled.
- Wired in: `CFBundleIconFile=AppIcon` in `Resources/Info.plist`; the bundle
  script copies the icns into `Contents/Resources`. As an `LSUIElement` app
  it shows only in Finder/Get Info. Geometry/palette verified by pixel
  sampling (corners transparent, arrows/meter correct); gates re-run green.

## Localization round (R9 revision, 2026-10-17)

- English + Simplified Chinese. Two mechanisms: SwiftUI literals localize via
  `LocalizedStringKey` + `Localizable.strings` (no code churn); code-built
  strings go through `App/L10n.swift` with the English text as the key, so a
  bundle without a matching lproj falls back to exactly the old English.
  Proper names (PT Monitor / qBittorrent / Transmission) are deliberately
  absent from the tables (missing-key fallback renders them verbatim).
- UI failure notes are two lines: localized cause headline + English technical
  detail (R6 diagnostics stay greppable). Form-validation messages in
  `ServerConfigValidation` localize; `HostFieldParser` parse errors stay English
  (cross-checked by `--selftest`, and shown only as the detail line).
- `scripts/check-localization.py` (wired into `build-app.sh`, pre-sign) fails
  the build unless every `*.lproj/Localizable.strings` carries the same key set
  — 59 keys per language. `CFBundleLocalizations` = [en, zh-Hans].
- `trellis-check` round caught and fixed: hardcoded Keychain save-failure
  message, missing tooltip key, 3 dead keys. Bundle binary selftest passes with
  `-AppleLanguages (zh-Hans)` forced — determinism proven on this machine,
  whose AppleLanguages lists zh-Hans.
- Gates: `swift build` 0 warnings, parity 59/59, `--selftest` 185 (raw + bundle,
  English + forced Chinese), bundle script green, codesign verify green.
- **Pending live verification**: GUI in each language (System Settings →
  per-app language, or reorder AppleLanguages).

## Live verification round 1 — the "banned IP" false alarm (2026-10-15)

First live qBittorrent configuration reported *"the server banned this IP
address"*. It was **not a ban** — it was a transport bug, and the message was a
mislabel. Root cause and fix:

1. `HTTPTransport` assigned a hand-made `HTTPCookieStorage()` to
   `URLSessionConfiguration.httpCookieStorage`. On macOS 12.7.6 the session then
   stores nothing and never replays the `SID` cookie, so every request after a
   successful login arrived sessionless. qBittorrent answers a sessionless
   private API call with **HTTP 403** (`webapplication.cpp`:
   `!session() && !isPublicAPI`), and `checkStatus` mapped every 403 to "banned".
   Fixed by relying on the ephemeral session's own private cookie store.
   Reproduced and verified against `scripts/fake-qbittorrent.py`.
2. `403` now means two different things and is no longer conflated: `auth/login`
   403 → `.banned` (the ban is the only `AccessDenied` that endpoint throws);
   any other 403 → `.protocolViolation` ("session cookie was not accepted"),
   and `authorizedGET` retries once on 401 **or** 403.
3. Added `ServerFailure.banned` with hard backoff (`bannedBackoff` 900 s; the
   credential backoff went 30 s → 600 s) after confirming from source that
   qBittorrent counts failed logins until a login *succeeds* (not time-limited)
   and bans at 5 for 3600 s — so the old 2 s/30 s timers could self-ban the IP.
4. `PreferencesView` now writes the Keychain password **before** the
   configuration and surfaces a Keychain failure in the editor instead of
   swallowing it, so an enabled server can no longer poll with an empty password.

Gates after the fix: clean build (0 warnings), `--selftest` 113 → **121 checks**,
`./scripts/build-app.sh` green, and the stub round-trip proves login → cookie →
`maindata` 200 → JSON, plus "auth failed" ×5 then the real `banned` branch.
