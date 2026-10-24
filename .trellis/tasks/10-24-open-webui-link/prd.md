# Open the server's WebUI from a torrent row

## Goal

Let the user jump from a torrent row in the panel to that **server's own web UI**
in the default browser, so inspecting or acting on a torrent (rename, files,
peers, category) no longer needs the URL typed by hand.

The action is **per server**, not global: the URL is derived from the row's own
`ServerConfig` (`host`, `port`, `useTLS`) and its `kind` decides the path. A row
in server A's section always opens server A's UI, whatever else is listed.

## Confirmed facts (code / upstream inspection 2026-10-24)

- `ServerConfig` carries `host`, `port`, `useTLS` (`ServerConfig.swift:37-39`)
  and `EndpointParser.baseURL(host:port:useTLS:)` already turns those into a
  validated scheme/host/port URL (`HTTPTransport.swift:41-52`), reusing
  `HostFieldParser` — the same parser preferences validation uses. No new
  host parsing is needed.
- **qBittorrent has no per-torrent web URL.** The WebUI (`5.x` master,
  `src/webui/www/private/scripts/client.js`) only understands
  `#download=<url>` (add-torrent); torrent selection is in-memory MochaUI state.
  The WebUI root is the served page.
- **Transmission has no per-torrent web URL either.** `web/src/transmission.js`
  only reads `?addtorrent=`; selection lives in `_selectedTorrentIds`. Its web
  client is served under `/transmission/web/` (`/transmission/rpc` is the RPC
  path, `TransmissionClient.swift:189`).
- Rows are tap-to-expand (`PanelView.row`, `PanelView.swift:489`); the read-only
  contract lives at `app-conventions.md:384-389` ("torrent rows may carry
  view-state interactions only … they must never carry a server action").
  Opening a browser makes **no** request, so the contract needs a carve-out
  rather than a rewrite.
- Panel width is fixed at 380pt and the collapsed row must not grow.

## Requirements

- R1. Every torrent row gets an "open in web UI" affordance. It opens the web
  UI of **that row's server** in the user's default browser.
- R2. URL construction is pure and lives in core, selftest-covered:
  `scheme://host:port` from `EndpointParser.baseURL`, plus `/transmission/web/`
  for `kind == .transmission`, nothing for `.qbittorrent`. Scheme follows
  `useTLS`; an invalid host yields no menu/affordance error state (the row still
  works).
- R3. No deep link is attempted (neither client supports one — see facts). The
  fragment/query is deliberately left off so the UI's own state decides.
- R4. The affordance is a **small trailing icon button on the row's name line**,
  visible without expanding (one click, no navigation detour). The row's tap
  gesture still expands; the button click must not also toggle the expansion.
- R5. It is an `NSWorkspace.shared.open` call in the app target — no RPC, no
  session cookie, no Keychain read. The panel is **not** dismissed by it
  (browser focus changes are outside the panel frame, so `PanelController`'s
  dismissal monitor will hide the panel — accepted, the user is leaving anyway).
- R6. The collapsed row height, the 3-layer anatomy and the 380pt width are
  unchanged; the name may truncate ~14pt earlier. Tooltip (`help`) names the
  action, localized en + zh-Hans like every other panel string.
- R7. Spec: §7 gets the carve-out ("opening a browser is an interaction, not a
  server action") plus the per-server URL rule and the no-deep-link fact;
  README gains the feature bullet.

## Acceptance Criteria

- [ ] AC1. `--selftest` asserts the built URL for both kinds, `useTLS` on/off,
      and a non-default port.
- [ ] AC2. Clicking the icon opens the correct server's web UI in the browser;
      the row does not expand/collapse from that click.
- [ ] AC3. Clicking elsewhere on the row still expands it, unchanged.
- [ ] AC4. Rows of server B open server B's URL even when server A's section is
      above them.
- [ ] AC5. `swift build` warning-free and `--selftest` green.
- [ ] AC6. Row height and panel width unchanged (visual check, dark + light).

## Out of scope

- In-app embedded web view, opening the *native* client app (magnet/`qbittorrent://`
  handlers), per-torrent deep links (unsupported upstream), auth into the web UI
  (the browser's own session/cookies apply).
