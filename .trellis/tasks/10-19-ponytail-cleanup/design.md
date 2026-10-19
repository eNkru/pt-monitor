# Design — ponytail cleanup

## Boundaries

Pure refactor. Two layers are touched:

- `PTMonitorCore` — `SelfTest`, `ServerConfigValidation`, `TorrentClient`'s
  `JSON` helpers, `ByteRateFormatter`, `SettingsStore`, `MonitorStore`,
  `AppLanguage`.
- `PTMonitor` (app) — `L10n`, `PanelView`, `ServerEditorView`,
  `AppDelegate`.

No new types, no new files, no dependency changes. `Package.swift` is
untouched. Two files are deleted outright (`App/PanelPreview.swift`,
`scripts/make-icon.swift`).

## Contracts that must not move

| Contract | Where it is asserted |
| --- | --- |
| Byte-rate / byte-count formatting, degradation ladder | `SelfTest.formatterChecks` |
| qBittorrent login 204/200/401/403 verdicts, non-login 403 ≠ ban | `SelfTest.clientChecks` |
| qB/Transmission state + eta tables, progress clamp, sort | `SelfTest.clientChecks` |
| `infoSegments` row decision, `percentText` | `SelfTest.rowChecks` |
| Host parsing, validator notices, port/scheme adjustments | `SelfTest.validationChecks` |
| Probe argv parsing + JSON shape | `SelfTest.probeChecks` |
| `isEquivalent`, `aggregate`, `menuBarState`, `retryDelay`, `poll` | `SelfTest.storeChecks` |
| Keychain never holds a password in `ServerConfig` | `app-conventions.md` §6 |

## Ordering / risk

Lowest risk first so a regression is attributable:

1. **Dead parameters and one-line collapses** (L10n, note, color, settings
   loaders, percentEncode, `start()`). No signature changes visible outside
   one file each.
2. **`JSON` helper removal.** 5 call sites, mechanical, fully selftest-covered.
3. **`ByteRateFormatter` scaling extraction.** Assertions unchanged.
4. **`SelfTest` harness consolidation** (shared `expect`, async `run()`).
   Touches only the checks themselves; assertion list must stay identical.
5. **`ServerConfigValidator` / `ServerConfigDraft` removal.** The only cut with
   a real signature change; `ServerEditorModel` follows in the same commit.
6. **D1** delete `--preview-panel` (`PanelPreview.swift`, the `main.swift`
   branch + usage line, `MonitorStore.setPreviewStatuses`) and the doc
   references to it.
7. **D2** delete `scripts/make-icon.swift`; fix the `README.md` and
   `build-app.sh` comments that name it.
8. **D3** delete `AppLanguage.init?(appleLanguageCode:)`; `loadAppLanguage`
   becomes `AppLanguage(rawValue:) ?? .system`.

## Rollback

Landed as **one commit** (the steps were applied in the order above but not
split; the diff is small enough to review whole and `git revert <sha>` reverts
it atomically). Step 5's `ServerConfigValidator` + `ServerEditorView` pair must
stay together if it is ever cherry-picked apart.

## Tradeoffs

- `SelfTest` gains a shared generic `expect`/`expectOptional` pair. It is one
  level of indirection, bought with ~90 duplicated lines — the audit's largest
  pure-duplication win.
- `SelfTest.run()` becomes `async`; `Box` stays (the `@Sendable` counting
  factory still needs a reference type) but `awaitBlocking`'s semaphore bridge
  goes away.
- `ServerConfigValidator.validate` takes `(ServerConfig, portText: String)`.
  A provisional `ServerConfig` with `port = Int(portText) ?? kind.defaultPort`
  is discarded on validation failure, so an unparsable port never escapes.
