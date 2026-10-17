# macOS Menu Bar PT Monitor

## Goal

A lightweight, native macOS menu bar app that connects to qBittorrent and/or
Transmission servers (on the user's NAS) and shows live transfer status at a
glance, without opening a browser. The app is read-only: it observes, it does
not control.

## Background (confirmed by inspection)

- This repository is greenfield: only Trellis scaffolding exists. No source
  files, no `Package.swift`, no build config.
- Development machine: macOS 12.7.6 (21H1320), Swift 5.7.2, **Command Line Tools
  only** — `xcodebuild` fails with `requires Xcode, but active developer
  directory ... is a command line tools instance`. macOS SDK 13.1 at
  `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`.
- Verified by experiment: `swiftc -target x86_64-apple-macos12.0
  -parse-as-library` builds a SwiftUI/`@main App` executable with CLT alone.
  **A full Xcode install is not required to build the app.**
- Verified by experiment: **`swift test` does not work with Command Line Tools
  alone.** A minimal SwiftPM package with a `testTarget` fails with
  `error: XCTest not available`. `XCTest.framework` ships only inside
  `Xcode.app/.../MacOSX.platform/Developer/Library/Frameworks`, and there is no
  `CommandLineTools/Platforms` directory here. Consequence: automated checks run
  through a built-in `--selftest` mode on the app binary, not through XCTest.
  Switching to XCTest later requires installing Xcode for the macOS 12 line
  (Xcode 14.x; Xcode 15+ requires macOS 13+), which needs the user's Apple ID.
- `swift package` (SwiftPM) is available. Outbound network works.
- Target servers are NAS-hosted (remote host, not localhost). Nothing torrent
  related is installed locally, so there is no local integration target;
  end-to-end verification must run against the user's NAS.
- `.trellis/spec/{backend,frontend}` are unfilled templates owned by the
  separate `00-bootstrap-guidelines` task. There are no project coding
  conventions yet to follow; `design.md` sets the conventions for this app.
- Deployment target is macOS 12.0, so `MenuBarExtra` (macOS 13+) is unavailable
  and the status item must be an AppKit `NSStatusItem`.

## Requirements

- **R1 — Menu bar agent.** Runs with no Dock icon and no window at launch;
  survives indefinitely with no windows open. `LSUIElement = YES`.
- **R2 — Two server types.** Supports qBittorrent (WebUI API v2) and
  Transmission (RPC) side by side.
- **R3 — Server configuration.** Add, edit, delete, and enable/disable server
  entries. Each entry has: type, display name, host, port, HTTPS toggle,
  "allow self-signed certificate" toggle, username, password.
- **R4 — Credential storage.** Passwords live in the macOS Keychain, never in
  the preferences plist.
- **R5 — Polling.** Each enabled server is polled on a configurable interval
  (default 2 s). Polling failures for one server never block another.
- **R5.1 — Menu bar display.** A template SF Symbol plus live speed text, e.g.
  `↓ 1.2M ↑ 340K`, aggregated across all enabled servers. The icon reflects
  state (idle / active / error). Template rendering so it adapts to light, dark,
  and highlighted menu bars.
- **R5.2 — Graceful width degradation.** The speed text uses tabular digits (no
  width jitter) and degrades to a more compact form, then to icon-only, when it
  would not fit — it is never truncated mid-number.
- **R5.3 — Menu bar text is optional.** A preference can hide the speed text and
  leave the icon alone.
- **R6 — Per-server error surfacing.** Connection failures appear against the
  specific server that failed, with a cause-specific message, while the other
  servers keep reporting normally.
- **R7 — Test connection.** A "Test Connection" action validates a configuration
  (including credentials) before saving.
- **R8 — Read-only.** No control actions. No torrent add/pause/resume/remove, no
  settings mutation on the remote server.
- **R9 — English + Simplified Chinese UI (revised 2026-10-17; originally
  "English UI").** Both languages ship in the bundle; macOS resolves per system
  preference (`CFBundleLocalizations` = en, zh-Hans). Translation keys are the
  English strings, so untranslated bundles fall back to English. Diagnostic
  detail (failure messages, `--probe`/`--selftest` output) stays English by
  design; the UI layer shows a localized cause headline with the English
  detail beneath it (R6).
- **R10 — CLT-only build.** `swift build` must succeed with Command Line Tools
  alone, and a script must assemble a launchable, ad-hoc-signed `.app` bundle.
- **R11 — Headless probe mode.** The binary supports a non-GUI probe of a single
  server that prints the fetched snapshot as JSON, so the API clients can be
  verified against a real NAS without the GUI.
- **R12 — Torrent list in the dropdown (added 2026-10-16, revised same day).**
  The dropdown embeds the torrent list of every enabled server, grouped per
  server. Each row shows: name, normalised state, progress, and live ↓/↑
  speed. The list updates with the poll cadence and is strictly read-only
  (R8). No separate window is opened (user revision, 2026-10-16: "embedded that
  list window just in dropdown? not open a new window").

## Acceptance Criteria

Verified on the dev machine (macOS 12.7.6) unless the criterion names the NAS.

- **AC1** `swift build -c release` succeeds using Command Line Tools only, with
  no Xcode installed.
- **AC2** `./scripts/build-app.sh` produces `build/PTMonitor.app`, and
  `open build/PTMonitor.app` adds a status item, shows no Dock icon, and opens
  no window. (R1, R10)
- **AC3** `swift run PTMonitor --selftest` exits 0 and reports every check as
  passed, covering: byte-rate formatting and its compact degradation, parsing of
  a recorded qBittorrent `maindata` response, a recorded Transmission
  `session-stats` response, and the qBittorrent `200 "Fails."` credential case.
  It exits non-zero with a readable message if any check fails. (XCTest is
  unavailable under Command Line Tools — see Background.)
- **AC4** First run with no configuration: the dropdown shows an empty state and
  an entry that opens Preferences. (R3)
- **AC5** Adding a qBittorrent server and using Test Connection reports success
  against the user's NAS; once saved and enabled, the menu bar shows live
  non-zero speeds while that server is transferring. (R2, R5, R5.1, R7)
- **AC6** Adding a Transmission server works the same way, with the
  `409`/session-id handshake handled automatically and never surfacing to the
  user. (R2, R5)
- **AC7** A wrong password on either server type produces a credential-specific
  error against that server in the dropdown, and the menu bar keeps showing
  correct aggregate speeds for the remaining healthy server(s). (R6)
- **AC8** An unreachable host (e.g. a bogus IP) produces an unreachable/timeout
  error against that server; the app stays responsive and other servers keep
  updating. (R6)
- **AC9** `defaults read <bundle-id>` and
  `plutil -p ~/Library/Preferences/<bundle-id>.plist` contain no password
  value, while the password is retrievable from the login Keychain. (R4)
- **AC10** With two servers each reporting 1.0 MB/s down, the menu bar shows an
  aggregate of `2.0M`. (R5.1)
- **AC11** Turning off the "show speeds" preference leaves the icon and hides the
  text; the icon still changes with state. (R5.3)
- **AC12** A disabled server is never contacted: no traffic and no error row for
  it. (R3, R5)
- **AC13** `PTMonitor --probe <type> --host <h> --port <p> [--user u] [--pass p]
  [--https] [--insecure]` prints a JSON snapshot and exits non-zero with a
  human-readable message on failure, without launching the GUI. (R11)
- **AC14** Menu bar width degradation is observable: a `--selftest` check on the
  formatter shows that an over-wide speed string shortens to the compact form
  and then to nil rather than being truncated mid-number. (R5.2)
- **AC15** Quit from the dropdown terminates the process cleanly. (R1)
- **AC16** With at least one server configured, the panel (Q5: the dropdown is
  a custom floating panel, no longer an `NSMenu`) embeds the torrent list;
  each enabled online server appears as a section with one row per torrent
  (name, state, progress, ↓/↑ speed); offline or failed servers show a
  per-server note instead of rows; the panel is fresh on every open and rows
  update live while it stays open. (R12, Q5)
- **AC17** `--selftest` covers the torrent-list normalisation: qBittorrent
  `state` strings and Transmission `status` integers map to the normalised
  `TorrentState`, progress is in 0…1, and the eta sentinels (qBittorrent
  `8640000`, Transmission `-1`/`-2`) render as unknown rather than a bogus
  number. (R12)
- **AC18** The embedded list has no control actions (R8); clicking outside the
  dropdown dismisses it and the status item keeps working. (R1, R12)

## Out of Scope

- **Control actions** (pause/resume, add/remove torrents, changing remote
  settings). The user explicitly deferred these: "start with read only first,
  then I can add later". The client layer is designed so they can be added
  without restructuring.
- Launch at login. Not requested; needs a LaunchAgent on macOS 12.
- Per-server poll intervals (one global interval for now).
- Notifications, Dock menu, torrent detail views (a per-torrent drill-down with
  files/trackers/peers — the list window of R12 is a summary, not a detail
  view), torrent search/indexers.
- Localization (English only), Mac App Store distribution, sandboxing,
  notarization, notarized/universal binaries, Windows/Linux builds.
- qBittorrent's `rid`-based delta sync (full snapshot per poll, by design — see
  `design.md`).

## Resolved Decisions

- **Q1 — Menu bar display.** User chose: icon **plus** combined live down/up
  speed text. (→ R5.1)
- **Q2 — Scope.** User chose: read-only monitoring first, control added later.
  (→ R8, Out of Scope)
- **Q3 — Torrent list presentation (2026-10-16).** User chose option B: a
  SwiftUI list, not richer NSMenu rows. (→ R12)
- **Q4 — Torrent list placement (2026-10-16, revision).** After seeing option B
  as a separate window, the user asked to embed the list directly in the
  dropdown instead of opening a window. Implemented as a view-based
  `NSMenuItem` hosting the same SwiftUI list. (→ R12, AC16)
- **Q5 — Dropdown presentation (2026-10-16).** User wants the CodexBar look
  (https://codexbar.app): the NSMenu dropdown is replaced by a custom floating
  panel (borderless `NSPanel` anchored under the status item) styled like
  CodexBar's popover — header with "Updated just now", aggregate number grid
  (↓/↑ speeds, active torrents, free space), per-server sections with torrent
  rows and pill progress meters, and footer action rows (Refresh /
  Preferences / Quit). Adaptive light/dark; dark mode matches the mockup.
  This supersedes Q4's `NSMenuItem` embedding mechanism (same data, same
  placement in the app, new chrome). (→ R12, AC16, AC18)

## Technical Notes

- No parent/child task split: the deliverables are not independently shippable —
  a client layer with no UI, or a UI with no clients, has no standalone value.
- API facts, field names, version gates, and ATS/Info.plist requirements are
  researched and cited in `research/apis.md`. `design.md` is the condensed
  decision record derived from it.
- Live NAS verification (AC5–AC8, AC10) requires the user's NAS reachable from
  the dev machine and its address/credentials. That is a verification step, not
  a planning blocker.
- No `Tests/` target and no XCTest dependency: `swift test` is broken under
  Command Line Tools (see Background). `PTMonitorCore` is still a separate
  library target from the `PTMonitor` executable so a future XCTest suite can be
  added by installing Xcode, with no restructuring.
- Self-check mode is part of the app binary (`--selftest`) rather than a test
  target, so `swift build` / `./scripts/build-app.sh` remain the only commands
  needed. This satisfies the original AC3 intent (automated, non-zero exit on
  failure) without XCTest.
