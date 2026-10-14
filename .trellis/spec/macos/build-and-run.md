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

- `SelfTest.run() -> SelfTest.Result` with `isSuccess`, `passed: Int`,
  `failure: String?`.
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

## 4. Gotcha: missing `PackageDescription.swiftinterface` under CLT

> **Warning**: A Command Line Tools 14.2 install missing
> `usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftinterface` makes every
> `swift build` fail with:
>
> ```
> Package.swift:2:8: error: no such module 'PackageDescription'
> ```

On Darwin SwiftPM ships the manifest module as a **`.swiftinterface`** (plus
`.swiftdoc`), not a binary `.swiftmodule` (see SwiftPM's
`Sources/PackageDescription/CMakeLists.txt`). The interface file was absent from
this machine's CLT install, and `/Library/Developer/CommandLineTools/...` is not
writable without `sudo`.

### Workaround (already installed)

A locally rebuilt interface is kept outside the system toolchain and selected
with SwiftPM's `SWIFTPM_CUSTOM_LIBS_DIR` (its `ManifestAPI/` child replaces
`<toolchain>/usr/lib/swift/pm/ManifestAPI`):

```
~/.ptmon-toolchain/pm/ManifestAPI/
  PackageDescription.swiftinterface
  PackageDescription.swiftdoc
  PackageDescription.swiftmodule
  libPackageDescription.dylib        # the original CLT dylib (ABI source of truth)

export SWIFTPM_CUSTOM_LIBS_DIR="$HOME/.ptmon-toolchain/pm"
```

A shim at `~/.local/bin/swift` (earlier in `PATH` than `/usr/bin`) sets that
variable only while the system file is missing, then `exec`s `/usr/bin/swift`.
It becomes a no-op the moment the system install is repaired.

### Regenerating the interface

If the CLT/toolchain changes, rebuild from the matching SwiftPM tag with the
exact CMake recipe. `PackageDescription/ContextModel.swift` is a symlink into
`Sources/PackageLoading/ContextModel.swift`, so extract both:

```bash
TAG=swift-5.7.2-RELEASE
curl -sL "https://github.com/apple/swift-package-manager/archive/refs/tags/$TAG.tar.gz" -o spm.tgz
tar -xzf spm.tgz "swift-package-manager-$TAG/Sources/PackageDescription" \
                 "swift-package-manager-$TAG/Sources/PackageLoading/ContextModel.swift"
PD=swift-package-manager-$TAG/Sources/PackageDescription
swiftc -module-name PackageDescription \
  -package-description-version 999.0 -enable-library-evolution \
  -emit-module-interface-path PackageDescription.swiftinterface \
  -emit-module-path PackageDescription.swiftmodule \
  -target x86_64-apple-macosx10.15 -swift-version 5 "$PD"/*.swift
```

### Permanent fix

Reinstalling Command Line Tools (`xcode-select --install`) or installing Xcode
restores the file and makes the shim/overlay unnecessary. Prefer the system fix
whenever the user can run it; do not commit any toolchain artifact to the repo.

## 5. Tests required

- Every change to `ByteRateFormatter`, parser/model mapping, `MonitorStore`
  decisions, host parsing, or the probe argv handling must add/extend a
  `--selftest` check with an explicit expected value.
- Network, Keychain, and GUI behaviour is **not** covered by `--selftest`;
  cover it with the `--probe` mode against a real server and the manual AC
  checklist.

## 6. Wrong vs Correct

#### Wrong

```bash
swift test                 # error: XCTest not available (CLT)
```

#### Correct

```bash
swift run PTMonitor --selftest
```
