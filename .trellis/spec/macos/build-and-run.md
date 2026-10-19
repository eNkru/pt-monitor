# Build and Run (PTMonitor)

## 1. Scope / Trigger

Read this before touching the build, the toolchain, or the test strategy. The
project builds with **Command Line Tools only** (no Xcode, no `xcodebuild`, no
`swift test`). This document records the exact commands, the toolchain gotcha
that blocks a fresh checkout, and the in-binary test contract.

## 2. Commands

```bash
swift build                          # debug build of PTMonitorCore + PTMonitor
swift run PTMonitor --selftest       # in-binary checks; exit 0 = all pass
swift build -c release               # release build
./scripts/build-app.sh               # assemble + ad-hoc sign build/PTMonitor.app
open build/PTMonitor.app             # run the menu bar agent (manual)

# headless single-server probe (R11 / AC13), no GUI:
build/PTMonitor.app/Contents/MacOS/PTMonitor \
  --probe <qbittorrent|transmission> --host <h> --port <p> \
  [--user u] [--pass p] [--https] [--insecure]

```

`swift test` is **forbidden** — XCTest is not shipped with Command Line Tools
(`error: XCTest not available`). Any `testTarget` breaks the build. Automated
checks live in `Sources/PTMonitorCore/Diagnose/SelfTest.swift` and run via
`--selftest`.

## 3. Contracts

### 3.1 `--selftest` contract

- `SelfTest.run() async -> SelfTest.Result` with `isSuccess`, `passed: Int`,
  `failure: String?`; `main.swift` awaits it at top level. Assertions go
  through the shared `SelfTest.Checks` helpers (`expect`, `expectOptional`,
  `expectContains`, `expectFailure`), not per-section copies.
- `main.swift` exits `0` when `isSuccess`, otherwise writes the first failure
  to stderr and exits `1`.
- Checks must be deterministic, fast, and free of network/GUI/Keychain side
  effects (the Keychain may prompt; never touch it in a check).
- Keep fixtures (recorded API payloads) as Swift string literals next to the
  checks so a future XCTest suite can reuse them verbatim.

### 3.2 Bundle requirements (`Resources/Info.plist`)

| Key | Value | Why |
| --- | --- | --- |
| `LSUIElement` | `YES` | menu-bar-only agent, no Dock icon |
| `LSMinimumSystemVersion` | `12.0` | deployment target |
| `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | `YES` | raw-IP/LAN HTTP; do **not** add `NSAllowsArbitraryLoads` |
| `NSLocalNetworkUsageDescription` | short string | required on macOS 15+ |
| `NSHighResolutionCapable` | `YES` | crisp status item |
| `CFBundleIdentifier` | `com.ptmonitor.PTMonitor` | must match `KeychainStore`'s service prefix |
| `CFBundle{Executable,Name,PackageType,ShortVersionString,Version}` | — | hand-assembled bundle plumbing |

## 4. Toolchain history and current state

### 4.1 Current (2026-10-16): macOS 14.8.9 + CLT 16.2

The machine was upgraded from macOS 12.7.6 to **macOS 14.8.9 (Sonoma)**, which
wiped the old CLT 14.2 install. Reinstalled **Command Line Tools 16.2**
(Swift 6.0.3) non-interactively:

```bash
touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
softwareupdate --list                      # shows "Command Line Tools for Xcode-16.2"
softwareupdate --install "Command Line Tools for Xcode-16.2"
```

With CLT 16.2 the §4.2 workaround is obsolete and **the shim at
`~/.local/bin/swift` was removed** (renamed to `swift.disabled-ptmon-shim`).
Leaving it in place silently injects the stale 14.2-era overlay from
`~/.ptmon-toolchain` and breaks every build with:

```
error: serialized JSON uses unsupported version 1, indicating use of a
mismatched PackageDescription library ...
```

If that error ever reappears, check `which swift` for shims before anything
else. Swift 6.0.3 also emits concurrency warnings the 5.7 toolchain did not:
`static let` constants on `@MainActor` classes must be declared
`public nonisolated static let` (see `MonitorStore`) — the build contract is
still **0 warnings**.

### 4.2 Historical: CLT 14.2 missing `PackageDescription.swiftinterface`

> Superseded by §4.1; kept because the machine may meet another half-installed
> CLT. A CLT install missing
> `usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftinterface` makes every
> `swift build` fail with `no such module 'PackageDescription'`. Darwin SwiftPM
> ships the manifest module as a `.swiftinterface`, not a binary
> `.swiftmodule`.

The workaround was a locally rebuilt interface at `~/.ptmon-toolchain/pm`
selected via `SWIFTPM_CUSTOM_LIBS_DIR`, set by a PATH shim at
`~/.local/bin/swift`. If it is ever needed again, regenerate the interface from
the matching SwiftPM tag (`swift-5.7.2-RELEASE`) with
`-package-description-version 999.0 -enable-library-evolution
-emit-module-interface-path` (full CMake-derived recipe was: extract
`Sources/PackageDescription` + the `ContextModel.swift` symlink target from the
SwiftPM tarball, compile all of `PackageDescription/*.swift`). Do not commit any
toolchain artifact to the repo.

### 4.3 ATS on macOS 14 (verified empirically, 2026-10-16)

`NSAllowsLocalNetworking=YES` (already in `Info.plist`) permits plain HTTP to
loopback and RFC1918 LAN addresses on macOS 14 — the NAS case works untouched.
It does **not** permit public-range IPs or public-style FQDNs; those fail with
`URLError.appTransportSecurityRequiresSecureConnection`, which
`HTTPTransport.describe` maps to a hint pointing at LAN addresses or HTTPS.
Verified matrix:

| Address | Result |
| --- | --- |
| `127.0.0.1` | reaches network (connection refused) |
| `192.168.x.x` | reaches network (timeout) |
| `203.0.113.99` (public-range IP) | ATS block |
| public FQDN + `http://` | ATS block |

## 5. Tests required

- Every change to `ByteRateFormatter`, parser/model mapping, `MonitorStore`
  decisions, host parsing, or the probe argv handling must add/extend a
  `--selftest` check with an explicit expected value.
- Network, Keychain, and GUI behaviour is **not** covered by `--selftest`;
  cover it with the `--probe` mode against a real server (or the stub in §7) and
  the manual AC checklist.
- **Panel appearance** is likewise not assertable in-binary: build the app
  (`./scripts/build-app.sh`), open it, and look at the panel with a real server
  (or the stub in §7) in light and dark mode. There is no fixture-render mode.
- **Any change to `HTTPTransport` needs a run against the stub**, not just a
  green `--selftest`. Cookie/session behaviour lives entirely inside URLSession
  and is invisible to network-free checks — that is exactly how the
  dropped-`SID`-cookie bug reached a user (see §7 and
  `app-conventions.md` §4.1).

## 6. Wrong vs Correct

#### Wrong

```bash
swift test                 # error: XCTest not available (CLT)
```

#### Correct

```bash
swift run PTMonitor --selftest
```

## 7. Verifying the transport without a NAS

`scripts/fake-qbittorrent.py` is a stdlib-only stub that mirrors the real
WebUI's auth and session behaviour (including the two distinct meanings of
`403`). Use it whenever the transport changes:

```bash
python3 scripts/fake-qbittorrent.py 18080 &
PTMONITOR=build/PTMonitor.app/Contents/MacOS/PTMonitor

# must print a JSON snapshot and exit 0
$PTMONITOR --probe qbittorrent --host 127.0.0.1 --port 18080 --user admin --pass adminadmin

# must say "auth failed", never "banned"
$PTMONITOR --probe qbittorrent --host 127.0.0.1 --port 18080 --user admin --pass wrong
```

Run it a 6th time with the wrong password and it must switch to the `banned`
message — that is the server's real ban branch (`MaxAuthenticationFailCount` is
5 by default). The stub's stderr log shows each request, so a sessionless `403`
is visible as `GET … -> 403 (no session cookie)`.

> **Warning**: the stub is a development tool, not part of the app. It is not
> shipped in the bundle and `scripts/build-app.sh` ignores it.
