# qBittorrent 5.2 login: accept 204 success / 401 failure

## Goal

`POST /api/v2/auth/login` against qBittorrent 5.2 succeeds with **HTTP 204 No
Content** (empty body). The client only accepts `200 + "Ok."`, so every login
against a 5.2 server is reported as failed ("login failed with HTTP 204") and
the qBittorrent server is unusable — even though the `SID` cookie was set.

## Background

Upstream change (verified in `release-5.2.0`, `src/webui/api/authcontroller.cpp`):

- 5.1 and older: `loginAction()` set a body — right credentials →
  `200 "Ok."`, wrong credentials → `200 "Fails."`.
- 5.2: `loginAction()` only sets an API **status**:
  - success → `setStatus(APIStatus::Ok)` with no data → `webapplication.cpp`
    `result.data.isNull()` → **`204`**, empty body, `Set-Cookie: SID=…`
  - wrong credentials → `throw APIError(Unauthorized)` → **`401 "Unauthorized"`**
  - banned IP → `throw ForbiddenHTTPError(...)` → **`403`** (unchanged meaning)

Observed on the user's export box (qBittorrent 5.2, `192.168.20.7:8085`):
a deliberately wrong password returns `401 Unauthorized`, and the app's "test
connection" surfaces the raw `204`.

The CSRF rule is unchanged: a request with neither `Origin` nor `Referer` is
still accepted, so no header change is needed.

## Requirements

- R1: `204` from `auth/login` is **success** (cookie is already set by the
  server; the session storage in `HTTPTransport` replays it).
- R2: `401` from `auth/login` → `.auth` ("invalid username or password"), with
  the body text passed through when it adds information.
- R3: keep the legacy behaviour: `200 "Fails."` → `.auth`, `200 "Ok."` →
  success (servers ≤ 5.1 must keep working). `403` → `.banned` (ban check still
  runs before credentials in 5.2, now inside `validateCredentials`).
- R4: `200` with an empty/blank body is still a protocol violation (no server
  version returns that, so it should stay loud rather than silently pass).
- R5: `--selftest` covers the 5.2 shapes (204, 401) alongside the legacy ones,
  and the stub WebUI (`scripts/fake-qbittorrent.py`) can speak 5.2 so the
  behaviour is reproducible end to end.
- R6: `.trellis/spec/macos/app-conventions.md` §4.1 documents the version
  matrix instead of claiming "wrong credentials return 200 Fails." as the only
  shape.

## Acceptance Criteria

- [x] `QBittorrentParser.loginFailure(statusCode: 204, body: "")` returns `nil`.
- [x] `QBittorrentParser.loginFailure(statusCode: 401, body: "Unauthorized")`
      is `.auth`.
- [x] `loginFailure(200, "Fails.")` is still `.auth`; `200, "Ok."` still `nil`;
      `403` still `.banned`; `200, ""` still `.protocolViolation`.
- [x] `--selftest` passes and its output lists the new cases (214 checks).
- [ ] Against a 5.2 server, "Test connection" reports
      `qBittorrent <ver> (WebAPI <ver>)` and a poll renders data. *(stub-verified
      with `WEBAPI=5.2`; needs the user's real box because the password lives in
      the Keychain)*
- [x] No unused variables / warnings; `swift build` clean.

## Result

- `QBittorrentParser.loginFailure` accepts `204` as success and maps `401` to
  `.auth`; the ≤ 5.1 shapes and the `403` ban are untouched.
- `scripts/fake-qbittorrent.py` speaks both generations (`WEBAPI=5.2`) and
  omits `Content-Length` on 204.
- Verified end to end against the stub in both modes: 204 → snapshot JSON,
  five wrong passwords → `auth failed`, then the 6th → `banned`.
- `.trellis/spec/macos/app-conventions.md` §4.1 now carries the version table.


## Notes

- Root cause is one parser function plus its tests; no transport or UI change
  is expected.
- Do not "fix" this by special-casing the version string — a 204 is
  self-describing and older servers never send it.
