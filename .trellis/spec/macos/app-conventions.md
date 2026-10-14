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
  (`NSStatusItem`, `NSMenu`, `NSApplication`) and SwiftUI views hosted in
  `NSWindow`/`NSHostingController`.
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
    case protocolViolation(String), serverError(String)
}   // ServerFailure conforms to Error so clients throw it directly
```

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
- Wrong credentials return **HTTP 200 with body `Fails.`** → `.auth`. Never
  infer auth failure from a 401 here. `Ok.` is not proof of credentials
  (localhost/subnet bypass).
- Poll `GET /api/v2/sync/maindata?rid=0` every time (full snapshot; no `rid`
  deltas). Do not use `/transfer/info`.
- `free_space_on_disk` only when cached `webapiVersion >= 2.1.1`; otherwise
  `nil`. Reject WebAPI `< 2.0` up front.
- Active = `state ∈ {downloading, metaDL, forcedDL, uploading, forcedUP,
  stalledDL, stalledUP}`; total = count of the `torrents` map.
- A `401` from a non-login endpoint → re-login once, retry once, then fail.

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

### 4.3 Transport

One `HTTPTransport` owns timeouts (5 s request / 15 s resource),
`waitsForConnectivity = false`, the ephemeral cookie storage, the opt-in
self-signed-trust delegate, Basic auth, and the 409 retry hook.

## 5. Polling and state

- `MonitorStore` is `@MainActor final class … : ObservableObject`.
- **One task per enabled server.** A slow/hanging server must never delay the
  others (R6). Disabled servers are never contacted (R3/AC12).
- Publish only when a status actually changes (ignore `fetchedAt`) to avoid
  menu-bar churn.
- **Credential-failure backoff is mandatory.** A wrong password normally
  re-polls every `pollInterval` (2 s), which trips qBittorrent's IP ban and
  Transmission's anti-brute-force lockout. `MonitorStore.retryDelay` backs off
  `credentialFailureBackoff = 30 s` on `.auth` and resets on success. Any new
  failure classification must be considered here.
- Inject the client factory and the sleep so checks never hit the network or
  wait on real time.

## 6. Persistence

- `UserDefaults` (via `SettingsStore` only): `servers` as JSON `[ServerConfig]`,
  `pollInterval` (default 2, clamp 1–60), `showSpeedsInMenuBar`.
- Passwords live **only** in the Keychain (`KeychainStore`,
  `kSecClassGenericPassword`, `service = <bundle-id>.server`,
  `account = <server UUID>`). Write only when non-empty; delete on clear or
  server delete. Never place a password in `ServerConfig` or defaults (R4/AC9).

## 7. Menu bar (macOS 12 — no `MenuBarExtra`)

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
- The menu is rebuilt on open/state change: aggregate header, per-server rows
  (cause-specific hint on failure), free-space row, Refresh ⌘R, Preferences ⌘,,
  Quit ⌘Q. Empty state on first run links to Preferences.
- **Read-only**: no pause/resume/add/remove. No control endpoints (R8).

## 8. Tests required

- Pure logic (formatter, parsers, host parsing, retry decisions) → a
  `--selftest` check with an explicit expected value.
- A parser/decoder change must update its recorded fixture **and** the
  assertion that reads it.
- `Sendable`/`@MainActor` correctness: clients are actors, `MonitorStore` is
  `@MainActor`; verify with a warning-free `rm -rf .build && swift build`.

## 9. Wrong vs Correct

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
