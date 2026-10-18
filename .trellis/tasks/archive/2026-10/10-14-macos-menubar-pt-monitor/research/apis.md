# HTTP API research: qBittorrent WebUI v2 + Transmission RPC (+ macOS ATS/Info.plist)

Task: `.trellis/tasks/10-14-macos-menubar-pt-monitor`
Researched: 2026-10-14. Scope: exact wire details for a Swift/AppKit poller. **No application code written.**

## Method / sources

Everything below is from upstream primary sources. Where the upstream *doc* and upstream *code* disagree, the code wins and the discrepancy is called out.

| Ref | Source | Retrieved |
| --- | --- | --- |
| QB41 | `https://raw.githubusercontent.com/qbittorrent/wiki/master/WebUI-API-(qBittorrent-4.1).md` | 2026-10-14 |
| QB50 | `https://raw.githubusercontent.com/qbittorrent/wiki/master/WebUI-API-(qBittorrent-5.0).md` | 2026-10-14 |
| QBKEY | `https://raw.githubusercontent.com/qbittorrent/wiki/master/API-Key-Authentication-(≥v5.2.0).md` | 2026-10-14 |
| QBCODE | `qbittorrent/qBittorrent` tag `release-5.0.0`, files `src/webui/webapplication.{h,cpp}`, `src/webui/api/{authcontroller,synccontroller,transfercontroller,apicontroller}.cpp`, `src/base/preferences.cpp` | 2026-10-14 |
| QBVER | `webapplication.h` `API_VERSION` sampled at tags `release-4.1.0 … release-5.2.4` | 2026-10-14 |
| TR406 | `https://raw.githubusercontent.com/transmission/transmission/4.0.6/docs/rpc-spec.md` (old bespoke protocol, kebab/camel) | 2026-10-14 |
| TRMAIN | `https://raw.githubusercontent.com/transmission/transmission/main/docs/rpc-spec.md` (JSON-RPC 2.0, snake_case, 4.1+) | 2026-10-14 |
| TRCODE | `transmission/transmission` tag `4.0.6`, `libtransmission/rpc-server.cc`, `libtransmission/rpcimpl.cc`, `libtransmission/session-id.h` | 2026-10-14 |
| APPL | Apple developer docs JSON API: `NSAppTransportSecurity`, `NSAllowsLocalNetworking`, `NSAllowsArbitraryLoads`, `NSLocalNetworkUsageDescription`, `com.apple.security.network.client`, `com.apple.security.app-sandbox`, `LSUIElement`, `Preventing Insecure Network Connections`, Technote **TN3179 (Understanding local network privacy)** | 2026-10-14 |

Note: the old single wiki page `WebUI-API-(qBittorrent-4.1+).md` no longer exists (404); the wiki was split into per-minor-version pages (4.1 / 5.0). QB41 is the relevant one for the 4.1–4.6.x range.

---

# 1. qBittorrent WebUI API v2

Base: `http://<host>:8080/api/v2/<scope>/<action>`. Port default 8080 is confirmed in code (`Preferences/WebUI/Port` default `8080`, QBCODE `preferences.cpp`).

## 1.1 Login

**`POST /api/v2/auth/login`** — POST only. Confirmed: `{auth/login} -> Http::METHOD_POST` in the `m_allowedMethod` table (QBCODE `webapplication.h`); since 4.4.4 a wrong verb returns **405** (QB41/QB50 "General Information").

- Request body: `application/x-www-form-urlencoded`, fields `username` and `password` (wiki example: `--data 'username=admin&password=adminadmin'`). QB41/QB50 Login section.
- `auth/login` is the one public (pre-session) endpoint: `declarePublicAPI(u"auth/login")` (QBCODE `webapplication.cpp`). `auth/logout` is also public but POST-only and harmless without a session.
- Success: `HTTP 200`, plain-text body **`Ok.`**, `Set-Cookie: SID=<base64 48-byte random>; path=/` (QB41 example). Source confirms the cookie is also `HttpOnly`, `SameSite=Strict` when CSRF protection is on, and `Secure` only if HTTPS + secure-cookie pref (QBCODE `sessionStart()`).
- **Wrong credentials: `HTTP 200` with body `Fails.` and no cookie** — *not* 401. This is the single most important gotcha; verified in QBCODE `authcontroller.cpp::loginAction()` (`setResult(u"Fails.")` in the else branch). A client must check the body, not the status code.
- **`HTTP 403`** when the client IP is banned after too many failed logins (`APIErrorType::AccessDenied` in `loginAction()`), or when the IP is outside the allowed subnet list / anti-brute-force limit (TR-style 403 equivalents are separate; for qBittorrent see `WebApplication::doProcessRequest` access checks). QB41/QB50 document 403 only for the ban case.
- Cookie name defaults to **`SID`**, overridable by the server pref `WebAPI/SessionCookieName` (QBCODE `preferences.cpp`). A robust client should read the cookie name from `Set-Cookie` rather than hardcoding.
- Session carried on later requests as `Cookie: SID=<value>`. Session timeout default is **3600 s of inactivity** (`Preferences/WebUI/SessionTimeout`, QBCODE); every authenticated request refreshes the timestamp, so normal polling never expires it.
- **`Referer` / `Origin` are optional.** CSRF protection is *on by default* (`Preferences/WebUI/CSRFProtection` default `true`). The check is `isCrossSiteRequest()`: if **both** `Origin` and `Referer` are absent the request is allowed (comment in source: "owasp.org recommends to block this request, but doing so will inevitably lead Web API users to spoof headers so lets be permissive here"). If either header *is* present it must be same-host **and same-port** as the request `Host` (scheme is not compared). Practical rule for the app: **send neither `Origin` nor `Referer`**, and set `Host` implicitly to the same `host:port` you dial. (`URLSession` does this by default; just do not add those headers.) The wiki's "Note: Set `Referer` or `Origin` header to the exact same domain and port" is only relevant if you send them.
- **Host-header validation is ON by default in 4.3.0 and in 5.0.0** (`Preferences/WebUI/HostHeaderValidation` default `true`, QBCODE/QBVER). It compares the `Host` header's host against the socket's local address, then against the wildcard list `Preferences/WebUI/ServerDomains`, whose **default is `*`** (matches anything). So with default settings nothing breaks; it only bites if the operator configures explicit server domains and the app connects by a name not in the list (→ `HTTP 401`).
- Alternative to cookies (5.2.0+ / WebAPI 2.14.1+): `Authorization: Bearer qbt_<28 chars>` API key; keys cannot call `auth/*`. See QBKEY. Not needed for the MVP but worth a note.
- Server-side ability detection without auth is impossible — `/api/v2/app/version` and `/api/v2/app/webapiVersion` both require a session. So: login first, then read `/api/v2/app/webapiVersion` + `/api/v2/app/version` to switch feature sets.

## 1.2 Which endpoint for a poller: `/sync/maindata` wins

**Use `GET /api/v2/sync/maindata?rid=<n>`. Do not poll `/transfer/info` + `/torrents/info`.**

- `/sync/maindata` returns, in one response: `rid`, `full_update`, `torrents` (object keyed by torrent hash, values *identical* to `/torrents/info` entries — QB50 "Get main data"), `torrents_removed`, `categories`, `categories_removed`, `tags`, `tags_removed`, `trackers`, `trackers_removed`, and **`server_state`**.
- `server_state` is the global transfer info **plus** the fields `/transfer/info` does not expose (all-time totals, free disk space, queueing, refresh interval). Source: `SyncController::makeMaindataSnapshot()` sets `serverState = getTransferInfo()` then adds `free_space_on_disk`, `queueing`, `use_alt_speed_limits`, `refresh_interval` (QBCODE `synccontroller.cpp`).
- Verified with source that **`/api/v2/transfer/info` returns only 8 keys**: `dl_info_speed`, `dl_info_data`, `up_info_speed`, `up_info_data`, `dl_rate_limit`, `up_rate_limit`, `dht_nodes`, `connection_status` (QBCODE `transfercontroller.cpp::infoAction()`). It has **no** `alltime_dl/ul`, **no** `free_space_on_disk`, **no** `global_ratio`. (The QB50 wiki table lists `queueing`/`use_alt_speed_limits`/`refresh_interval` under `/transfer/info`; that is a doc bug — the code does not return them there. They appear only in `maindata.server_state`.)
- `rid` = response ID, a monotonically increasing counter cycling 1…1 000 000. Semantics (QBCODE `synccontroller.cpp::maindataAction()`):
  - `full_update = true` unless you send a `rid > 0` that equals the server's last *accepted* id, in which case it returns only deltas.
  - So **omitting `rid` (or sending `rid=0`) always yields a complete snapshot** — the right choice for a simple poller. If you want the bandwidth win, keep the `rid` from the last reply and merge deltas using `*_removed` arrays, but that requires a real CRDT-ish merge and is a correctness risk for a menu-bar app. Recommendation for MVP: `rid=0` every poll; the payload is small (only the fields actually serialized) compared to two round-trips.
  - Note: `full_update=false` deltas are diffed against the server's *per-session* snapshot, so a fresh `rid=0` request after re-login is always safe.

## 1.3 Exact response field names (qBittorrent)

**Global speeds / totals / status / free space — `server_state` in `/sync/maindata` (QB50 "Get main data"; verified in QBCODE `synccontroller.cpp` + `transfercontroller.cpp`):**

| Concern | Field | Type | Notes |
| --- | --- | --- | --- |
| Global down speed | `dl_info_speed` | int, bytes/s | present since API 2.0 |
| Global up speed | `up_info_speed` | int, bytes/s | present since API 2.0 |
| Downloaded **this session** | `dl_info_data` | int, bytes | name is misleading: session-scoped |
| Uploaded **this session** | `up_info_data` | int, bytes | session-scoped |
| Cumulative downloaded (all-time) | `alltime_dl` | int, bytes | in `maindata` only |
| Cumulative uploaded (all-time) | `alltime_ul` | int, bytes | in `maindata` only |
| Global ratio | `global_ratio` | **string** (`"-"` or `"1.23"`) | in `maindata` only; string, not float |
| Waste this session | `total_wasted_session` | int | |
| Connections | `total_peer_connections` | int | |
| DHT nodes | `dht_nodes` | int | |
| Connection status | `connection_status` | string | `connected` \| `firewalled` \| `disconnected` |
| Rate limits | `dl_rate_limit`, `up_rate_limit` | int, bytes/s | |
| **Free disk space** | `free_space_on_disk` | int, bytes | **on the *default save path*, not per-torrent** |
| Queueing enabled | `queueing` | bool | maindata only |
| Alt speed limits | `use_alt_speed_limits` | bool | maindata only |
| UI refresh interval | `refresh_interval` | int, ms | maindata only |
| Cache/disk extras | `read_cache_hits`, `total_buffers_size`, `write_cache_overload`, `read_cache_overload`, `queued_io_jobs`, `average_time_queue`, `total_queued_size` | mixed | present in `maindata` only; mostly useless in a menu bar app |

Important: `dl_info_data`/`up_info_data` are **session** counters (reset when the qBittorrent process restarts). Use `alltime_dl`/`alltime_ul` for a lifetime total, or sum per-torrent `downloaded`/`uploaded`. Free space is a single value, cached server-side and refreshed by a periodic `FreeDiskSpaceChecker` wired up in `sessionStart()` (QBCODE `webapplication.cpp`), i.e. **it is only populated after a WebUI session exists**.

**Per-torrent (identical dict inside `maindata.torrents` and array elements from `/torrents/info`):** the fields a poller needs are `hash`, `name`, `dlspeed`, `upspeed`, `progress` (0…1 float), `state` (string), `eta`, `ratio`, `size`, `total_size`, `downloaded`, `uploaded`, `downloaded_session`, `uploaded_session`, `amount_left`, `save_path`, `content_path`, `tags` (comma-joined string), `category`, `num_seeds`, `num_leechs`, `num_complete`, `num_incomplete`, `added_on`, `completion_on`, `last_activity`, `priority`, `dl_limit`, `up_limit`, `seeding_time`, `time_active`, `isPrivate` (5.0.0+). Full table in QB50 "Get torrent list".

`state` possible values (identical tables in QB41 and QB50): `error`, `missingFiles`, `uploading`, `pausedUP`, `queuedUP`, `stalledUP`, `checkingUP`, `forcedUP`, `allocating`, `downloading`, `metaDL`, `pausedDL`, `queuedDL`, `stalledDL`, `checkingDL`, `forcedDL`, `checkingResumeData`, `moving`, `unknown`.

## 1.4 Which qBittorrent/WebAPI version each field appeared in

`API_VERSION` is a hard-coded constant in `src/webui/webapplication.h`. Sampled (QBVER):

| qBittorrent tag | WebAPI version |
| --- | --- |
| release-4.1.0 | 2.0.0 |
| release-4.1.1 | 2.0.1 |
| release-4.1.2 | 2.0.2 |
| release-4.1.3 | 2.1.0 |
| **release-4.1.4** | **2.1.1** |
| release-4.1.5 / .6 / .7 / .8 | 2.2.0 |
| release-4.1.9 | 2.2.1 |
| release-4.2.0 | 2.3.0 |
| release-4.2.1 | 2.4.0 |
| release-4.2.5 | 2.5.1 |
| release-4.3.0 | 2.6.0 |
| release-4.3.3 | 2.7.0 |
| release-4.3.9 | 2.8.2 |
| release-4.4.0 | 2.8.4 |
| release-4.4.1 / .5 | 2.8.5 |
| release-4.5.0 | 2.8.18 |
| release-4.5.5 | 2.8.19 |
| release-4.6.0 | 2.9.2 |
| release-4.6.2 / .7 | 2.9.3 |
| release-5.0.0 / 5.0.1 | 2.11.2 |
| release-5.1.0 / 5.1.4 | 2.11.4 |
| release-5.2.0 / 5.2.4 | 2.15.1 |

Field-level history relevant to graceful degradation:

- `dl_info_speed`, `dl_info_data`, `up_info_speed`, `up_info_data`, `dl_rate_limit`, `up_rate_limit`, `dht_nodes`, `connection_status`, `alltime_dl`, `alltime_ul`, `global_ratio`, `total_wasted_session`, `total_peer_connections`, `read_cache_hits`, `total_buffers_size`, `read_cache_overload`, `write_cache_overload`, `queued_io_jobs`, `average_time_queue`, `total_queued_size` — **all present at API 2.0 (qBittorrent 4.1.0)**; verified by grepping the `KEY_TRANSFER_*` literals in `synccontroller.cpp` at `release-4.1.0`. So the entire global-stats set (except free space) is safe on 4.1+.
- **`free_space_on_disk` was added in WebAPI 2.1.1 → qBittorrent 4.1.4** (QB41 changelog "API v2.1.1": "Add `free_space_on_disk` field to `/sync/maindata` (#8217)"; PR #8217 merged 2018-10-28; the literal is absent from `release-4.1.0/.1/.2/.3` and present from `release-4.1.4`). Degrade: treat the key as optional; on 4.1.0–4.1.3 fall back to `/api/v2/torrents/properties` → `free_space_on_disk`? — **not verified**; the safe fallback is "hide the free-space widget".
- `/torrents/info` gains that matter: `hashes` param (2.0.1), `content_path` (2.6.1), `seeding_time` (2.8.1), `tag` filter (2.8.3), `reannounce` field (2.9.3), `isPrivate` (5.0). None are needed for the MVP; all array-element keys you rely on (`hash`, `name`, `progress`, `state`, `dlspeed`, `upspeed`, `eta`, `ratio`, `size`, `downloaded`, `uploaded`) exist since 2.0.
- Robust approach: parse `maindata.server_state` into a struct with optionals; call `/api/v2/app/webapiVersion` once after login and gate `free_space_on_disk` on `>= 2.1.1`, `isPrivate` on `>= 2.11.2`.
- API v2 was introduced by qBittorrent **4.1.0**; anything older speaks the `v3.2.0-v4.0.4` / `v3.1.x` API and should be rejected up front with a clear message.

## 1.5 Degenerate / auth-bypass behaviours

- **"Bypass authentication for clients on localhost"**: server pref `Preferences/WebUI/LocalHostAuth`, default **`true`**, where `true` means *authentication is required even on loopback*. The UI checkbox is the inverse. When the operator unticks it (`LocalHostAuth=false`), `WebApplication::isAuthNeeded()` returns false for loopback clients and `sessionInitialize()` **auto-creates a session** (`sessionStart()`), so every subsequent API call succeeds with no cookie. Consequence: a `login` call from such a client hits `if (m_sessionManager->session()) { setResult("Ok."); return; }` and returns `Ok.` **even with wrong credentials**. A client must therefore not use "login returned non-Ok" as the only reachability test, and should tolerate a session that appears pre-authenticated. (No cookie is necessarily returned in the bypass case because the session was created implicitly — **not verified** whether `Set-Cookie` still accompanies it in this path; treat cookie presence as optional and fall back to "request succeeded without cookie".)
- There is also a **subnet whitelist** (`isWebUIAuthSubnetWhitelistEnabled` + `auth_subnet_whitelist`) that bypasses auth for configured subnets — same consequence. **Not required for the MVP** but the client should not assume a login round-trip is always needed.
- Wrong credentials → `200 "Fails."` (see §1.1). Banned IP → `403`. Wrong HTTP verb → `405`. CSRF/host-header rejection → `401` with a plain-text body. A 401 from a *non-login* endpoint means "session gone or host header rejected" → re-login once and retry once, then surface an error (avoid a login loop).

---

# 2. Transmission RPC

Two protocol generations are in the field. Decide per server from the 409 response (§2.1.4).

- **Old bespoke protocol** (kebab-case + camelCase): Transmission **1.30 … 4.0.x**, `rpc-version` 1…17, `rpc-version-semver` up to 5.3.0. This is what virtually every NAS package (Synology/QNAP/Asustor) ships today. Spec: TR406.
- **JSON-RPC 2.0 + snake_case**: Transmission **4.1.0+**, `rpc_version` 18, `rpc_version_semver` 6.0.0. Old strings are still accepted but deprecated. Spec: TRMAIN.
- Endpoint: `POST /transmission/rpc` on port **9091** by default, JSON body, no `Content-Type` requirement documented but `application/json` is conventional. TR406/TRMAIN §"Transport mechanism".

## 2.1 The `X-Transmission-Session-Id` handshake

Verified in **TRCODE `libtransmission/rpc-server.cc::handle_request()`** (4.0.6), which is the normative ordering:

1. `403` if anti-brute-force tripped or the client IP is not allowed (`rpc-whitelist`).
2. `200` for `OPTIONS` (CORS preflight).
3. **Basic-auth check** → `401` + `WWW-Authenticate: Basic realm="Transmission"` if enabled and header missing/wrong.
4. Host whitelist (DNS-rebinding) → **`421`** if the `Host` name is not whitelisted.
5. **Session-id check** (`#ifdef REQUIRE_SESSION_ID`, compiled in by default) → **`409`** with the correct id in the **`X-Transmission-Session-Id` response header** (and `Access-Control-Expose-Headers: X-Transmission-Session-Id`).
6. Actual RPC handling.

So, concretely, on the first request without the header the server returns **HTTP 409** and the response header `X-Transmission-Session-Id: <48-char id>`; the body is an HTML help paragraph. The client reads that header, **re-sends the exact same request** with `X-Transmission-Session-Id: <id>` and succeeds with `200`. This must be handled **on every request, forever** — not just the first one — because the id **rotates**:

- TRCODE `libtransmission/session-id.cc` + `session-id.h`: `SessionIdDurationSec = 60 * 60` — **the session id expires every hour**, and the "send 409, client retries" cycle is the designed refresh path. A 24/7 poller will hit this roughly hourly.
- In modern Transmission the id is one process-wide value (not per-session), regenerated on rotation and on restart.

Practical client state machine: keep `sessionId: String?`; send it if present; on **409** capture the header, store it, retry the same request **once** (guard against loops); on repeated 409 give up and report. Never treat 409 as a fatal error.

### 2.1.1 Basic auth interaction

- Auth is checked **before** the session-id step (step 3 vs step 5 above). Therefore with a wrong password you get **`401`**, never a `409`; you never even see the session id. Order for the client: **401 → credential error; 409 → session-id refresh; 200 → parse body.**
- Header format: `Authorization: Basic base64(username:password)` (TRCODE `isAuthorized()`).
- "If password auth is enabled, any hostname is permitted" (`isHostnameAllowed()` short-circuits to true) — i.e. enabling auth **disables** the host-whitelist 421 check. Useful note for the UI: telling a user to set credentials also removes DNS-rebinding friction.
- The username/password storage is salted-SHA1 server-side; irrelevant to the client.
- Anti-brute-force: repeated 401s trip a temporary `403` for that IP (`login_attempts_`). So a poller must **back off hard on 401** rather than retrying on a short timer.

### 2.1.2 Request envelope (old protocol, TR406 §2.1)

```json
{ "method": "session-get", "arguments": { }, "tag": 912313 }
```

- `method` — required string.
- `arguments` — optional object.
- `tag` — optional number; "If provided by a request, the response **MUST** include the same tag."
- Response: `{"result":"success"|"<error string>","arguments":{…},"tag":<echoed>}`, and **HTTP 200 is returned regardless of success/failure** (TRMAIN states this explicitly for the new protocol too; TR406's envelopes all show 200). Therefore **the client must branch on the `result` string**, not the HTTP status. Omission of `tag` is allowed; echoing it is a cheap way to sanity-check that a response belongs to the request (useful if you ever pipeline). Recommendation: always send `tag` and verify the echo.

### 2.1.3 Request envelope (JSON-RPC 2.0, TRMAIN §2, Transmission 4.1+)

```json
{ "jsonrpc": "2.0", "method": "session_get", "params": { }, "id": 912313 }
```

Response: `{"jsonrpc":"2.0","result":{…},"id":912313}`, errors under `error` with `code`/`message`/`data`. Notifications return HTTP 204. Method names use `_` instead of `-` (`session_get`, `torrent_get`, `free_space`), and all argument/response keys are snake_case (`rate_download`, `download_speed`, `percent_done`, `size_bytes`, …).

### 2.1.4 Detecting which protocol a server speaks

TRMAIN §5: "Starting from `rpc-version-semver` 6.0.0, Transmission returns the RPC version in an HTTP header **`X-Transmission-Rpc-Version: {rpc_version_semver}` in the CSRF HTTP 409 response**" — e.g. `6.0.0`. So the very first unauthenticated POST doubles as the capability probe: 409 → read both `X-Transmission-Session-Id` and (if present) `X-Transmission-Rpc-Version`. Header present and `>= 6.0.0` → use JSON-RPC 2.0 + snake_case; absent → old protocol. (**Caveat, flagged:** headers are only guaranteed on 4.1.0+; on a 4.0.x or older server only the session-id header appears, which is exactly the "old protocol" signal.)

Also usable: `session-get` → `rpc-version` (int, 1…19) for old servers, `rpc-version-semver` (string, 4.0.0+) for 4.0/4.1. Simplest robust strategy for the MVP: **support only the old bespoke protocol** (works on 1.30–4.0.x, and 4.1+ still accepts it with a deprecation warning) — but note the deprecation warning says old strings "will be removed in the future", so keying off `X-Transmission-Rpc-Version` and adding a snake_case path later is the future-proof move.

## 2.2 Methods and fields needed by the poller

### session metadata + cumulative stats

| Need | Old protocol (TR406) | JSON-RPC 2.0 (TRMAIN) |
| --- | --- | --- |
| Version, download dir | `session-get` with `arguments.fields`, or no `fields` for everything. Keys: `version`, `rpc-version`, `rpc-version-semver` (4.0+), `download-dir`, `download-dir-free-space` (**deprecated** in 4.0) | `session_get`, keys `version`, `rpc_version`, `rpc_version_semver`, `download_dir` |
| Cumulative + current stats | `session-stats` → `activeTorrentCount`, `downloadSpeed` (B/s), `pausedTorrentCount`, `torrentCount`, `uploadSpeed` (B/s), `cumulative-stats`, `current-stats` | `session_stats` → `active_torrent_count`, `download_speed`, `paused_torrent_count`, `torrent_count`, `upload_speed`, `cumulative_stats`, `current_stats` |
| Stats object keys | `uploadedBytes`, `downloadedBytes`, `filesAdded`, `secondsActive`, `sessionCount` | `uploaded_bytes`, `downloaded_bytes`, `files_added`, `seconds_active`, `session_count` |

For a menu bar app the cheapest useful pair is:
1. `session-stats` — gives global down/up speed (`downloadSpeed`/`uploadSpeed`) + torrent counts in one call, no per-torrent loop. Note these are the values Transmission itself displays; they are **B/s**.
2. `torrent-get` with a small `fields` list for the list view: `id`, `name`, `status`, `percentDone`, `rateDownload`, `rateUpload`, `eta`, `uploadRatio`, `totalSize`, `downloadedEver`, `uploadedEver`, `isStalled`, `error`, `errorString`, `downloadDir`, `labels`, `queuePosition`, `addedDate`, `doneDate`.
   - `ids` may be omitted (gives all torrents) or `"recently-active"` (delta mode returning a `removed` array). `format` may be `"objects"` (default) or `"table"` (arrays of arrays — more compact to parse; avoid for MVP clarity).
   - `percentDone` is 0…1 double; `metadataPercentComplete` is 0…1; `sizeWhenDone`/`totalSize`/`leftUntilDone` are bytes; `rateDownload`/`rateUpload` are bytes/s; `uploadRatio` is a double; `eta` is seconds (can be `-1`/`-2` for unknown — from `tr_stat`, **not restated in the spec table**, flagged as unverified).
3. `free-space` for the download dir (see below).

`torrent-get` `fields` is **required** in the old protocol (TR406: "A required `fields` array"). Omitting it is an error on some builds — always send it explicitly.

### free space

- **`free-space`** (old) / `free_space` (4.1+) — TR406 §4.7 / TRMAIN §4.7:
  - Request: `{"path": "/abs/path"}`. Response: `{"path": "<same>", "size-bytes": <free bytes>, "total_size": <capacity bytes>}` (snake_case `size_bytes`/`total_size` in 4.1+).
  - Availability: **added in Transmission 2.80** (`rpc-version` 15) per TRMAIN §5. Before 2.80 the only option is `session-get` → `download-dir-free-space` (added 2.20 / rpc 12), which is **deprecated as of 4.0 and may be absent in future builds**.
  - `total_size` was added by **Transmission 4.0.0** (rpc 17); on 2.80–3.0x expect only `size-bytes`.
  - Errors: non-absolute path → `"directory path is not absolute"`; missing `path` arg → `"directory path argument is missing"`; otherwise `tr_strerror(errno)` from the failing `statvfs`/`GetDiskFreeSpaceEx` — e.g. a nonexistent directory or an unmounted share returns an error string with `result != "success"`. Verified in TRCODE `rpcimpl.cc::freeSpace()`.
  - Blocking: the handler is **synchronous** — it calls `tr_dirSpace(path)` (a `statvfs()`/`GetDiskFreeSpaceEx()` syscall) inline on the RPC thread and returns the result immediately; there is no `idle_data` deferral (the `tr_rpc_idle_data*` parameter is unused, see the signature). So it is not "async" but it is a single syscall — normally microseconds. **Known real-world caveat:** on a NAS where the download dir lives on an NFS/SMB/CIFS mount, `statvfs` can block for a long time if the remote server is unresponsive, and the RPC call will hang until it returns. **Not verified from upstream docs** (no upstream statement found); treat as an operational risk: issue `free-space` on a separate lower-frequency cadence from the speed poll, with a short client-side timeout and graceful degradation.
  - Whether `free-space` is "supported on NAS builds": the method is **not** platform-conditional in the source — it is registered unconditionally in the method table (TRCODE `rpcimpl.cc`: `{ "free-space"sv, true, freeSpace }`). It is compilation-flag-free. So a NAS build of Transmission ≥2.80 supports it; the failure modes are permission/path/mount related, not build related. That said, some NAS vendors ship *patched* builds; not verifiable in general.

### torrent status integers (identical in TR406 and TRMAIN, and **unchanged since Transmission 2.40**, which bumped rpc to 14 with "values of `status` field changed")

| Value | Meaning |
| --- | --- |
| 0 | Torrent is stopped |
| 1 | Queued to verify local data |
| 2 | Verifying local data |
| 3 | Queued to download |
| 4 | Downloading |
| 5 | Queued to seed |
| 6 | Seeding |

A menu bar app typically maps `4`/`6` to "active", `3`/`5` to "queued", `0` to "stopped", `1`/`2` to "checking", and uses `error != 0` (plus `errorString`) for the error state. `isStalled` (rpc 14+, Transmission 2.40+) flags stalled-but-running torrents.

## 2.3 Other Transmission gotchas worth encoding

- **`421` DNS-rebinding**: returned when the `Host` header (port stripped) is not `localhost`, not an IP literal, and not in `rpc-host-whitelist`; only applies when password auth is **off** (auth on ⇒ any hostname allowed) and whitelisting is on (default on). Connecting **by IP** always passes. Recommendation: dial by IP, and if a user configures a hostname, surface a specific "add the hostname to rpc-host-whitelist or enable auth" hint on 421.
- **`403`**: IP not in `rpc-whitelist`, or anti-brute-force lockout after repeated auth failures. Both are configuration/backoff problems, not "server down".
- Old protocol keys that mix cases are real and must be matched exactly: `downloadSpeed`, `rateDownload`, `percentDone`, `uploadedBytes`, `size-bytes`, `total_size`, `download-dir`. Only the *snake_case* form is regular; the old form is inconsistent by design (that is precisely why 4.1 changed it).
- `result` is `"success"` (not a boolean, not HTTP-status-derived). Error responses still come back as HTTP 200 with a descriptive `result` string.

---

# 3. Cross-cutting: macOS ATS + Info.plist

## 3.1 App Transport Security and plain `http://` on the LAN

Facts, all from APPL:

1. **ATS applies only to the URL Loading System** (`URLSession` and friends): "The system enforces ATS when you use the standard [`URLSession`]. **ATS doesn't apply to calls your app makes to lower-level networking interfaces like the [`Network`] framework or [BSD sockets]**." So if you ever swap to `NWConnection`, ATS is out of the picture (and you own TLS/security decisions). With `URLSession` (the recommended path), ATS applies.
2. ATS is **on by default for any app linked against the macOS 10.11 SDK or later**, "no matter which version of operating system your app runs on"; linking an older SDK disables it. A SwiftPM build with contemporary Command Line Tools links a modern SDK ⇒ **ATS is active**, regardless of sandbox, signing, or `CLT`-only toolchain.
3. **Per-OS behaviour for local names/addresses** (APPL `NSAllowsLocalNetworking`, verbatim substance):
   - iOS 9 / macOS 10.11: ATS **blocks** unqualified domains, `.local` domains, and IP addresses.
   - **iOS 10–16 / macOS 10.12–13: ATS allows all three by default** — "you no longer need an exception for any of them".
   - iOS 17 / **macOS 14+: ATS no longer allows connections to IP addresses by default**; you must list IPs/CIDR ranges in `NSExceptionDomains` (or set the local-networking key).
4. Therefore, **on macOS 12 with an `http://` URL pointing at a LAN IP such as `192.168.1.50:8080`, no ATS exception is required at all.** Same for a bare hostname (`nas`) or `nas.local`. What *would* be blocked is `http://` to a fully-qualified public-style name (e.g. `nas.example.com`) — and the same app running on macOS 14+ would be blocked for raw-IP URLs unless an exception is present.
5. **Version-portability recommendation** (Apple's own guidance): set `NSAllowsLocalNetworking = YES` — "the local networking exception tells newer versions of the OS to ignore the arbitrary loads key, and enable access to unqualified domains, `.local` domains, and IP addresses that they would otherwise restrict". Apple adds: "While ATS doesn't block local loads by default in newer versions of the OS, consider setting `NSAllowsLocalNetworking` to `YES` as a declaration of intent."
   - Do **not** bother with `NSAllowsArbitraryLoads` for this app: on macOS 10.12+ it is **ignored** whenever `NSAllowsLocalNetworking` is present (APPL `NSAllowsArbitraryLoads`: "the value of the `NSAllowsArbitraryLoads` key is ignored … if any of the following keys are present"), and it is a wider, less defensible exception.
   - Minimal recommended `Info.plist` fragment:
     ```xml
     <key>NSAppTransportSecurity</key>
     <dict><key>NSAllowsLocalNetworking</key><true/></dict>
     ```
6. **Sandboxed vs non-sandboxed:** ATS is orthogonal to the App Sandbox — it is enforced by CFNetwork/URLSession for both. The sandbox adds a *separate* restriction: a sandboxed app needs the **`com.apple.security.network.client`** entitlement ("allow your sandboxed app to connect to a server process running on another machine, or on the same machine"; APPL). A pure client does **not** need `com.apple.security.network.server` (that is for listening/accepting connections, and for UDP receiving the docs note "Apps using UDP usually require both entitlements" — irrelevant here). An **unsandboxed** app needs neither entitlement. A SwiftPM-built, non-signed/ad-hoc `.app` is unsandboxed unless you explicitly add `com.apple.security.app-sandbox` *and* sign with entitlements, so for a personal build you can ignore the sandbox entirely.
7. **macOS 12 differs from macOS 13+ only in nothing; it differs from macOS 14+ for raw IPs.** macOS 13 is still in the "10.12–13 allows all three by default" bucket; macOS 14 is the first OS that restricts IP-address ATS loads. Since the deployment target is 12.0 and users may run the binary on 14/15, ship `NSAllowsLocalNetworking=YES` and you are covered across 10.12→15+.

## 3.2 Info.plist keys for a plain-LAN menu-bar client on macOS 12

| Key | Required? | Why |
| --- | --- | --- |
| `LSUIElement` = `YES` | Not required by the OS, but **required for the intended UX**: "A Boolean value indicating whether the app is an agent app that runs in the background and doesn't appear in the Dock" (APPL). Without it the app gets a Dock icon and a default menu bar; with it, you own the status item. | Menu-bar-only behaviour |
| `NSLocalNetworkUsageDescription` | **Not required on macOS 12.** Apple's availability metadata lists macOS 11.0+, but local network *privacy enforcement* only exists where the feature is shipped: per **TN3179**, "The following platforms support local network privacy: … **macOS yes — macOS 15**" (iOS/iPadOS 14, visionOS 1). On macOS 12 there is no Local Network TCC prompt and no enforcement. Including the string is harmless and Apple suggests "Any app that uses the local network, directly or indirectly, should include this description", so add it as future-proofing (it will be needed if the app is ever run on macOS 15). | Not enforced on 12 |
| `NSBonjourServices` | **Not required** unless you actually browse/advertise Bonjour service types. Apple: "If your app's local network usage involves registering or browsing for specific Bonjour services, add a list of service types to the `NSBonjourServices` property." A menu-bar client that talks to a user-typed `host:port` over TCP is *not* a Bonjour client, so this key is unnecessary. It is also only meaningfully enforced under the same macOS 15+ local-network-privacy regime. | Only for Bonjour/multicast discovery |
| `NSAppTransportSecurity` / `NSAllowsLocalNetworking` | Not required on macOS 12 for LAN IPs/unqualified/`.local` URLs (§3.1), **recommended** for macOS 14+ forward-compat. | See §3.1 |
| `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundleName`, `CFBundlePackageType` = `APPL`, `CFBundleShortVersionString`/`CFBundleVersion`, `LSMinimumSystemVersion` = `12.0` | Required for a hand-assembled SwiftPM `.app` to be recognised as a launchable agent app at all (not ATS-related). `CFBundleIdentifier` also matters for TCC/permission identity stability. | Bundle plumbing |
| `NSHighResolutionCapable` = `YES` | Recommended so status-item/menu text is not blurry on Retina. | Rendering quality |
| Multicast entitlement `com.apple.developer.networking.multicast` | **Not needed** — only for multicast, per TN3179 ("if your iOS app performs multicast operations, sign it with the multicast entitlement"). Not applicable to a unicast HTTP client. | N/A |
| `NSSupportsAutomaticTermination` / `NSSupportsSuddenTermination` | Not needed; avoid — they let the system kill the polling agent. | N/A |

Sandbox entitlements, if the app is ever sandboxed: `com.apple.security.app-sandbox` + `com.apple.security.network.client`. On macOS 12 no local-network entitlement/prompt is involved.

---

# 4. Recommended implementation shape (derived, not yet code)

- qBittorrent: one `GET /api/v2/sync/maindata?rid=0` per poll; login once with `POST /api/v2/auth/login` (form-encoded, no `Origin`/`Referer`); accept `200 "Fails."` as a credential error; re-login + retry once on `401`; treat `free_space_on_disk`/`isPrivate` as optional keys.
- Transmission: `POST /transmission/rpc` with `session-stats` and `torrent-get`, plus a separate low-frequency `free-space`; implement the `409 → read header → retry once` loop for **every** request (not just the first) because the id rotates hourly; branch on `result`/`error`, not HTTP status; 401 ⇒ stop and back off; 421 ⇒ hostname hint; 403 ⇒ whitelist/lockout hint.
- ATS: `NSAllowsLocalNetworking=YES` in `Info.plist`; use `URLSession` and dial by IP or `hostname.local`.
- Locale: qBittorrent's `state` is a stable enum-like string; Transmission's `status` is an int. Keep the two native models separate and normalise into one domain enum (`downloading/seeding/paused/stalled/checking/error/queued`).

# 5. Explicitly NOT verified (do not assert)

1. Whether `Set-Cookie` is still emitted when a session is auto-created by the localhost auth bypass (the code returns early from `login`, and `sessionStart()` does set the cookie; the implicit path in `sessionInitialize()` also calls `sessionStart()`, so it very likely does — but I did not trace the response-header flush for that path).
2. Whether a `.app` bundle assembled by hand from SwiftPM output requires the `Host` header to be set explicitly (it should not), and whether `URLSession` adds an `Origin`/`Referer` under any configuration — I only verified the server side.
3. The exact free-space fallback available on qBittorrent **4.1.0–4.1.3** (pre-WebAPI-2.1.1). No per-torrent free-space field was confirmed.
4. Behaviour of the *patched* Transmission builds that NAS vendors ship (Synology/QNAP); upstream source is unconditional, vendor patches are not inspected.
5. `eta` sentinel values (`-1`/`-2`) for Transmission — present in `tr_stat` semantics but not restated in either spec table I read.
6. Whether the qBittorrent WebUI, when "bypass authentication for localhost" is enabled, still requires a `Host` header that passes host-header validation — I read `validateHostHeader` but did not confirm the bypass ordering relative to it (both are inside the same `try` block; the CSRF/host check runs *before* `sessionInitialize()`, so it applies to bypassed clients too; the default `ServerDomains = *` makes this a non-issue in practice).
