# Ponytail cleanup: remove duplication and dev-only code

## Goal

Apply the repo-wide over-engineering audit (ponytail-audit) to PTMonitor:
delete duplicated code, dead parameters, and copy-paste blocks. Behaviour must
not change. Target ≈ −330 lines net of the dev-tool decisions below.

## Requirements

- **R1 — Behaviour preserving.** No change to polling, backoff, parsing,
  persistence, menu bar text, panel layout, or localization output.
- **R2 — No coverage loss.** `--selftest` must keep every existing assertion.
  A cut that removes the only check for a documented contract is out of scope.
- **R3 — Build contract.** `swift build` stays at **0 warnings** (CLT 16.2 /
  Swift 6.0.3, see `.trellis/spec/macos/build-and-run.md` §4.1).
- **R4 — Localization gate.** No `Resources/*.lproj` key changes; if any, both
  tables in the same change (`scripts/check-localization.py`).
- **R5 — Spec first.** Any cut that changes a documented convention updates
  `.trellis/spec/macos/app-conventions.md` in the same change.

## Acceptance Criteria

- [x] AC1 `swift build` — 0 warnings.
- [x] AC2 `swift run PTMonitor --selftest` exits 0, `passed` count ≥ baseline.
- [x] AC3 Forced zh-Hans selftest passes:
      `swift run PTMonitor --selftest -AppleLanguages '(zh-Hans)'`.
- [x] AC4 `./scripts/build-app.sh` assembles and ad-hoc signs the bundle.
- [x] AC5 `--probe qbittorrent` against `scripts/fake-qbittorrent.py` still
      prints a JSON snapshot; wrong password still says "auth failed", not
      "banned" (transport untouched, run as regression proof).
- [x] AC5b `--preview-panel` no longer exists: an unknown `--option` prints the
      usage and exits **2** (a silent GUI launch would look like success), and
      `PanelPreview`/`setPreviewStatuses` are gone from the tree and from every
      `.md` that documented them. Single-dash args (`-AppleLanguages …`) still
      launch the agent.
- [x] AC5c `scripts/make-icon.swift` is gone and no `.md`/`.sh` still tells the
      reader to run it.
- [x] AC5d Language picker still round-trips: `setAppLanguage(.chinese)` writes
      `appLanguage` + `AppleLanguages`, `.system` clears the override, and a
      fresh store reads the persisted choice back.
- [x] AC6 `git diff --stat` shows a net line reduction, with no file added.
- [x] AC7 `app-conventions.md` / `build-and-run.md` still describe the code
      (grep the touched symbols; update or confirm).

## Out of scope (audit findings rejected after reading the specs)

- `HTTPTransport`'s session-level `didReceive` challenge. `app-conventions.md`
  §4.3: the task-level method forwards to it and is the load-bearing one on
  current macOS. Keeping both is deliberate.
- `MonitorStore.startTask`'s inline poll. It deliberately **reuses** one client
  across polls to keep auth state (SID / session id); `poll()` builds a fresh
  client per call. Not duplication.
- `TransmissionParser.snapshot(fromResponseBody:)` and
  `SessionIdHandshake.step()`. They are the only pure, selftest-covered
  expressions of "result string decides success" and "a second 409 never
  recurses". Deleting them trades lines for coverage (violates R2).
- `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`. Returning
  `false` is not provably the framework default for this app shape; leaving a
  one-line guard is cheaper than an agent that quits on window close.

## Decisions pending (owner: Howard)

- **D1 `--preview-panel` (`PanelPreview.swift` + `MonitorStore.setPreviewStatuses`).**
  ~200 lines. It is the *only* way to inspect panel rendering
  (`build-and-run.md` §5). Delete only if the panel is verified by eye in the
  running app.
- **D2 `scripts/make-icon.swift`.** ~210 lines, one-shot generator;
  `Resources/AppIcon.icns` is committed. Delete unless icons will be
  regenerated.
- **D3 `AppLanguage` `AppleLanguages` migration.** ~25 lines, defends a
  pre-switcher `defaults write` state. Delete → picker shows "Follow System"
  for such a user (cosmetic).
