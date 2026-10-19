# Implement — ponytail cleanup

## Pre-flight

```bash
cd /Users/howard/Sources/pt-monitor
swift build 2>&1 | tail -5                       # expect 0 warnings
swift run PTMonitor --selftest                    # record baseline `passed` count
```

Baseline `passed` = **214** (0 warnings), recorded 2026-10-19 before step 1.

## Steps

Each step = one commit. Run `swift build && swift run PTMonitor --selftest`
after every step.

- [x] 1. Dead parameters / one-line collapses
  - [ ] `L10n.s(_:comment:)` → `s(_:)` (`Sources/PTMonitor/App/L10n.swift`)
  - [ ] `PanelView.note(_:isError:)` → `note(_:)` (`PanelView.swift`)
  - [ ] `PanelView.color(for:)`: merge `.queued, .checking, .paused, .other`
  - [ ] `SettingsStore.loadShowSpeeds` / `loadShowActiveTorrentsOnly`:
        `defaults.object(forKey:) as? Bool ?? default`
  - [ ] `QBittorrentClient.percentEncode`: single `union` expression
  - [ ] delete `MonitorStore.start()`; `AppDelegate` calls `reconcile()`
  - [ ] `MonitorStore.stop()` / `reconcile()` share `cancelAllTasks()`
- [x] 2. `TorrentClient.swift`: delete `JSON.string` / `JSON.int`
  - [ ] `JSON.string(x)` → `x as? String` (5 sites)
  - [ ] `JSON.int(x)` → `JSON.int64(x).map(Int.init)` (2 sites)
- [x] 3. `ByteRateFormatter`: extract the shared unit-scaling loop used by
      `rate` and `bytes`; assertions unchanged
- [x] 4. `SelfTest`: hoist one generic `expect` + `expectOptional` pair to the
      enum, delete the 6 local copies, make `run()`/section funcs `async`,
      delete `awaitBlocking` (keep `Box`)
- [x] 5. `ServerConfigValidator`
  - [ ] delete `ServerConfigDraft`
  - [ ] `validate(_ config: ServerConfig, portText: String) throws -> Validated`
  - [ ] `Validated.notices: [String]` → `notice: String?`
  - [ ] `ServerEditorModel.draft()` builds the provisional `ServerConfig`;
        `.notices.first` → `.notice`
  - [ ] `SelfTest.validationChecks` updated for the new signature and for
        `notice`
- [x] 6. D1: delete `--preview-panel`
  - [ ] delete `Sources/PTMonitor/App/PanelPreview.swift`
  - [ ] `main.swift`: drop the argv branch and the usage line
  - [ ] `MonitorStore`: drop `setPreviewStatuses`
  - [ ] `build-and-run.md` §2 command + §5 bullet; `app-conventions.md` §5 bullet
- [x] 7. D2: delete `scripts/make-icon.swift`; fix the `README.md` lines (3)
      and the `build-app.sh` comment
- [x] 8. D3: delete `AppLanguage.init?(appleLanguageCode:)`;
      `loadAppLanguage` → `AppLanguage(rawValue:) ?? .system`
- [x] 9. Spec update: `app-conventions.md` §4.3 confirmed (both challenge hooks
      kept), §5 `setPreviewStatuses` bullet removed, §6/§10 unchanged; record
      the `ServerConfigValidator` signature if referenced

## Verification (all of AC1–AC7)

```bash
swift build 2>&1 | grep -i warning                  # must print nothing
swift run PTMonitor --selftest                      # AC2: exit 0, passed >= baseline
swift run PTMonitor --selftest -AppleLanguages '(zh-Hans)'   # AC3
./scripts/build-app.sh                              # AC4 + localization gate
python3 scripts/fake-qbittorrent.py 18080 &         # AC5
build/PTMonitor.app/Contents/MacOS/PTMonitor --probe qbittorrent \
  --host 127.0.0.1 --port 18080 --user admin --pass adminadmin
build/PTMonitor.app/Contents/MacOS/PTMonitor --probe qbittorrent \
  --host 127.0.0.1 --port 18080 --user admin --pass wrong   # "auth failed"
kill %1
git diff --stat                                     # AC6: net negative
grep -rn "ServerConfigDraft\|awaitBlocking\|JSON\.string\|JSON\.int(" Sources/
                                                    # must print nothing
grep -rn "PanelPreview\|setPreviewStatuses\|preview-panel" Sources/ README.md \
  scripts/ .trellis/spec/                            # must print nothing
grep -rn "make-icon" README.md scripts/ .trellis/spec/   # must print nothing
grep -rn "appleLanguageCode" Sources/               # must print nothing
swift run PTMonitor --preview-panel /tmp/x.png; echo "exit=$?"   # AC5b: usage, exit 0
```

## Result (2026-10-19)

All steps applied. `swift build` 0 warnings; `--selftest` **218** passed (was
214: −1 replaced structurally, +5 added for the validator and language paths);
zh-Hans-forced run 218; bundle assembled (74 keys × 2 languages); probe against
the stub returns a snapshot and "auth failed" for a wrong password;
`git diff --stat` = 20 files, +407 −955 (net **−548**), no file added.
One extra change the plan missed: `main.swift` now rejects unknown `--options`
(exit 2), otherwise a removed flag silently launched the GUI. Single-dash
`NSArgumentDomain` overrides still pass through.

## Review gates

- After step 4: re-read the `SelfTest` diff and confirm the **assertion list**
  is unchanged (only the harness moved).
- After step 5: run the manual Preferences flow — add a server with
  `http://nas.local:9091`, confirm the HTTPS/port notice still appears once.
- Before commit of step 5: `grep -rn ServerConfigDraft .trellis/spec` and update
  if referenced.
