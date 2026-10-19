#!/usr/bin/env python3
"""A stub qBittorrent WebUI, for verifying the client without a NAS.

Why this exists: the real WebUI has behaviours that no network-free check can
reproduce — most importantly that a private API call made *without a session* is
answered with HTTP 403, the same status the login ban uses. A transport bug that
dropped the `SID` cookie therefore looked exactly like "the server banned this
IP", and 121 in-binary checks could not tell the difference. This stub can.

It mirrors qBittorrent 4.6.0 (and, with `WEBAPI=5.2`, 5.2) exactly where it
matters:

  src/webui/api/authcontroller.cpp::loginAction()
      - banned IP          -> APIErrorType::AccessDenied   => HTTP 403
      - wrong credentials  -> setResult("Fails.")          => HTTP 200
      - right credentials  -> sessionStart() + "Ok." + Set-Cookie: SID
  src/webui/api/authcontroller.cpp::increaseFailedAttempts()
      - counts every failed login until a login SUCCEEDS (not time-limited)
      - bans at `MaxAuthenticationFailCount`
  src/webui/webapplication.cpp::doProcessRequest()
      - `!session() && !isPublicAPI` -> ForbiddenHTTPError  => HTTP 403
  src/base/preferences.cpp
      - WebUI/MaxAuthenticationFailCount default 5
      - WebUI/BanDuration                default 3600 s

`WEBAPI=5.2` switches it to the 5.2 shapes, which moved the verdict from the
body to the status (upstream `authcontroller.cpp::loginAction`):

  - banned IP          -> ForbiddenHTTPError           => HTTP 403
  - wrong credentials  -> APIError(Unauthorized)       => HTTP 401
  - right credentials  -> no result data               => HTTP 204 (no body)

Usage:

    python3 scripts/fake-qbittorrent.py [port]        # default 18080
    PTMONITOR=build/PTMonitor.app/Contents/MacOS/PTMonitor
    $PTMONITOR --probe qbittorrent --host 127.0.0.1 --port 18080 \\
        --user admin --pass adminadmin

Expected: a JSON snapshot and exit 0. Wrong credentials must report
"auth failed" (not "banned") for the first `MaxAuthenticationFailCount`
attempts, and only then "banned". Repeat with `WEBAPI=5.2 python3
scripts/fake-qbittorrent.py` — the logins are a 204 and a 401 there, and the
outcome must be identical.

`COOKIE_MODE` (strict|lax|none|bare) varies the `Set-Cookie` attributes, which
is how the cookie-storage bug was isolated. The stub logs every request to
stderr, so it also shows whether the SID was replayed.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

USER = "admin"
PASS = "adminadmin"
MAX_FAILS = 5
SID = "stubSIDvalue123"
# qBittorrent 5.2 signals login success/failure with the status code alone.
API52 = os.environ.get("WEBAPI") == "5.2"

fail_count = 0
banned = False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("stub: " + (fmt % args) + "\n")

    # --- helpers ---------------------------------------------------------
    def has_session(self):
        return SID in (self.headers.get("Cookie") or "")

    def respond(self, code, body=b"", headers=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        # 204 carries no body, so it carries no Content-Length either.
        if code != 204:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def forbidden(self):
        # Exactly what webapplication.cpp throws for a sessionless private call.
        self.respond(403, "Forbidden")

    # --- routes ----------------------------------------------------------
    def do_POST(self):
        global fail_count, banned
        if not self.path.startswith("/api/v2/auth/login"):
            self.respond(404, "not found")
            return

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode()
        params = dict(p.split("=", 1) for p in body.split("&") if "=" in p) if body else {}
        user = params.get("username", "").replace("+", " ")
        password = params.get("password", "").replace("+", " ")

        if banned:
            sys.stderr.write("stub: login -> 403 BANNED (IP ban branch)\n")
            self.respond(403, "Your IP address has been banned after too "
                              "many failed authentication attempts.")
            return

        if user == USER and password == PASS:
            fail_count = 0
            mode = os.environ.get("COOKIE_MODE", "strict")
            attrs = {"strict": "; HttpOnly; SameSite=Strict",
                     "lax": "; HttpOnly; SameSite=Lax",
                     "none": "; HttpOnly",
                     "bare": ""}[mode]
            cookie = {"Set-Cookie": f"SID={SID}; path=/{attrs}"}
            if API52:
                sys.stderr.write("stub: login -> 204 (session started, no body)\n")
                self.respond(204, "", cookie)
            else:
                sys.stderr.write("stub: login -> 200 Ok. (session started)\n")
                self.respond(200, "Ok.", cookie)
            return

        fail_count += 1
        if fail_count >= MAX_FAILS:
            banned = True
            sys.stderr.write(f"stub: login -> fail (attempt {fail_count}, NOW BANNED)\n")
        else:
            sys.stderr.write(f"stub: login -> fail (attempt {fail_count}/{MAX_FAILS})\n")
        if API52:
            self.respond(401, "Unauthorized")
        else:
            self.respond(200, "Fails.")

    def do_GET(self):
        if not self.has_session():
            sys.stderr.write(f"stub: GET {self.path} -> 403 (no session cookie)\n")
            self.forbidden()
            return
        if self.path.startswith("/api/v2/app/webapiVersion"):
            self.respond(200, "2.15.1" if API52 else "2.11.2")
        elif self.path.startswith("/api/v2/app/version"):
            self.respond(200, "v5.2.0" if API52 else "v4.6.0")
        elif self.path.startswith("/api/v2/sync/maindata"):
            self.respond(200, json.dumps({
                "rid": 1,
                "full_update": True,
                "torrents": {
                    "a" * 40: {"hash": "a" * 40, "name": "t1", "state": "downloading"},
                    "b" * 40: {"hash": "b" * 40, "name": "t2", "state": "stalledUP"},
                },
                "server_state": {
                    "dl_info_speed": 1258291,
                    "up_info_speed": 348160,
                    "connection_status": "connected",
                    "free_space_on_disk": 442918502400,
                },
            }))
        else:
            self.respond(404, "not found")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    sys.stderr.write(f"stub: listening on 127.0.0.1:{port}\n")
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
