"""HTTP front end: small JSON API over the cached cabinet inventory."""
from __future__ import annotations

import ipaddress
import json
import re
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import actions, emucfg, emulators, frontend, gamelist, scores
from .cache import InventoryCache

# path -> allowed methods
ROUTES = {
    "/health": {"GET"},
    "/v1/inventory": {"GET"},
    "/v1/refresh": {"POST"},
    "/v1/emulators": {"GET"},
    "/v1/gamelist": {"POST", "PUT"},
    "/v1/emulators/default": {"POST", "PUT"},
    "/v1/emulators/pin": {"POST", "PUT", "DELETE"},
    "/v1/frontend/refresh": {"POST"},
    "/v1/frontend/restart": {"POST"},
    "/v1/scores": {"GET"},
    "/v1/scores/file": {"GET", "PUT"},
}
MAX_JSON_BODY = 64 * 1024
MAX_GAMELIST_BODY = 2 * 1024 * 1024  # a batch of games with their descriptions
GAME_ROUTE = re.compile(r"^/v1/games/([^/]+)/([^/]+)$")


class _TooLarge(Exception):
    pass


def is_allowed_client(ip: str) -> bool:
    """Only private-network, link-local and loopback clients are served (the API has no authentication)."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if getattr(addr, "ipv4_mapped", None):
        addr = addr.ipv4_mapped
    return addr.is_private or addr.is_loopback or addr.is_link_local


class Context:
    def __init__(self, cache: InventoryCache, version: str = "dev", attract_bin: str = frontend.ATTRACT_BIN):
        self.cache = cache
        self.version = version
        self.attract_bin = attract_bin
        self.started = time.time()


def _handler_for(ctx: Context):
    class Handler(BaseHTTPRequestHandler):
        server_version = "rinkmasterd"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # systemd/journal friendly, one line per request
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

        def _send(self, code: int, body: bytes = b"", headers=None):
            self.send_response(code)
            headers = dict(headers or {})
            self.send_header("Content-Type", headers.pop("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(body)))
            for k, v in headers.items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, code: int, obj, headers=None):
            self._send(code, json.dumps(obj, sort_keys=True).encode(), headers)

        def _dispatch(self):
            if not is_allowed_client(self.client_address[0]):
                return self._json(403, {"error": "forbidden: private network clients only"})
            parts = urllib.parse.urlsplit(self.path)
            path, query = parts.path, urllib.parse.parse_qs(parts.query)
            game = GAME_ROUTE.match(path)
            methods = {"DELETE"} if game else ROUTES.get(path)
            if methods is None:
                return self._json(404, {"error": "not found"})
            method = "GET" if self.command == "HEAD" else self.command  # HEAD is GET without a body
            if method not in methods:
                return self._json(405, {"error": "method not allowed"}, {"Allow": ", ".join(sorted(methods))})
            self.query = query
            if game:
                return self._delete_game(urllib.parse.unquote(game.group(1)), urllib.parse.unquote(game.group(2)), query)
            getattr(self, "_" + path.strip("/").replace("/", "_"))()

        do_GET = do_HEAD = do_POST = do_DELETE = do_PUT = _dispatch

        def _health(self):
            self._json(200, {"ok": True, "version": ctx.version, "machine": ctx.cache.hostname,
                             "uptimeSeconds": int(time.time() - ctx.started)})

        def _v1_inventory(self):
            r = ctx.cache.get()
            headers = {"ETag": r.etag, "X-Cache": "hit" if r.hit else "miss"}
            if self.headers.get("If-None-Match") == r.etag:
                return self._send(304, b"", headers)
            self._send(200, r.body, headers)

        def _v1_emulators(self):
            data = emulators.list_emulators(ctx.cache.configs_path)
            data["machine"] = ctx.cache.hostname
            self._json(200, data)

        def _flag(self, key):
            return self.query.get(key, ["0"])[0] in ("1", "true", "yes")

        def _body_object(self, limit=MAX_JSON_BODY):
            """The request's JSON object body; raises emucfg.BadRequest (400) or _TooLarge (413)."""
            length = int(self.headers.get("Content-Length") or 0)
            if length > limit:
                self.close_connection = True
                raise _TooLarge()
            try:
                obj = json.loads(self.rfile.read(length).decode("utf-8"))
            except ValueError:  # includes UnicodeDecodeError and JSONDecodeError
                raise emucfg.BadRequest("request body must be a JSON object")
            if not isinstance(obj, dict):
                raise emucfg.BadRequest("request body must be a JSON object")
            return obj

        def _emulator_change(self, change):
            try:
                result = change()
            except emucfg.BadRequest as e:
                return self._json(400, {"error": str(e)})
            except emucfg.NotFound as e:
                return self._json(404, {"error": str(e)})
            except _TooLarge:
                return self._json(413, {"error": "request body too large"}, {"Connection": "close"})
            if result["changed"] and not result["dryRun"]:
                ctx.cache.refresh()
            result["machine"] = ctx.cache.hostname
            self._json(200, result)

        def _v1_emulators_default(self):
            def change():
                body = self._body_object()
                return emucfg.set_default(ctx.cache.configs_path, body.get("system"), body.get("emulator"),
                                          dry_run=self._flag("dryRun"))
            self._emulator_change(change)

        def _v1_emulators_pin(self):
            def change():
                if self.command == "DELETE":  # clear: ?system=&game=
                    q = lambda k: self.query.get(k, [None])[0]  # noqa: E731
                    system, game, emulator = q("system"), q("game"), None
                else:
                    body = self._body_object()
                    system, game, emulator = body.get("system"), body.get("game"), body.get("emulator")
                if emulator == "":
                    emulator = None
                return emucfg.set_pin(ctx.cache.configs_path, system, game, emulator, dry_run=self._flag("dryRun"))
            self._emulator_change(change)

        def _v1_gamelist(self):
            try:
                body = self._body_object(MAX_GAMELIST_BODY)
                result = gamelist.upsert(ctx.cache.configs_path, body.get("system"), body.get("games"), dry_run=self._flag("dryRun"),
                                         roms=ctx.cache.roms_path, auto_media=body.get("autoMedia") is True,
                                         only_missing=body.get("onlyMissing") is True)
            except (emucfg.BadRequest, gamelist.BadRequest) as e:
                return self._json(400, {"error": str(e)})
            except _TooLarge:
                return self._json(413, {"error": "request body too large"}, {"Connection": "close"})
            self._json(200, result)

        def _delete_game(self, system, name, query):
            def flag(key):
                return query.get(key, ["0"])[0] in ("1", "true", "yes")
            roms, cfgs = ctx.cache.roms_path, ctx.cache.configs_path
            try:
                plan = actions.plan_removal(roms, cfgs, system, name, with_art=flag("withArt"),
                                            with_saves=flag("withSaves"), with_scores=flag("withScores"))
                if flag("dryRun"):
                    plan["dryRun"] = True
                    return self._json(200, plan)
                plan["removed"] = actions.apply_removal(roms, cfgs, system, name, plan)
                plan["dryRun"] = False
                ctx.cache.refresh()
                plan["frontend"] = frontend.refresh_lists(cfgs, system, ctx.attract_bin)
                self._json(200, plan)
            except actions.BadRequest as e:
                self._json(400, {"error": str(e)})
            except actions.NotFound as e:
                self._json(404, {"error": str(e)})

        def _v1_scores(self):
            data = scores.list_scores(ctx.cache.roms_path)
            data["machine"] = ctx.cache.hostname
            self._json(200, data)

        def _v1_scores_file(self):
            q = lambda k: self.query.get(k, [""])[0]  # noqa: E731
            try:
                if self.command == "PUT":
                    length = int(self.headers.get("Content-Length") or 0)
                    if length > scores.MAX_SCORE_BYTES:
                        if length <= 1 << 20:
                            self.rfile.read(length)  # drain so the client sees the answer, not a reset
                        self.close_connection = True
                        return self._json(413, {"error": "score file too large"}, {"Connection": "close"})
                    result = scores.write_score(ctx.cache.roms_path, q("core"), q("kind"), q("game"), self.rfile.read(length))
                    return self._json(200, result)
                body = scores.read_score(ctx.cache.roms_path, q("core"), q("kind"), q("game"))
            except scores.BadRequest as e:
                return self._json(400, {"error": str(e)})
            except scores.NotFound as e:
                return self._json(404, {"error": str(e)})
            self._send(200, body, {"Content-Type": "application/octet-stream"})

        def _v1_frontend_refresh(self):
            system = self.query.get("system", [""])[0]
            if not actions.NAME_RE.match(system) or ".." in system:
                return self._json(400, {"error": "a valid ?system= is required"})
            self._json(200, frontend.refresh_lists(ctx.cache.configs_path, system, ctx.attract_bin))

        def _v1_frontend_restart(self):
            force = self.query.get("force", ["0"])[0] in ("1", "true", "yes")
            try:
                self._json(200, frontend.restart(ctx.cache.configs_path, force=force, attract_bin=ctx.attract_bin))
            except frontend.Busy as e:
                self._json(409, {"error": str(e)})

        def _v1_refresh(self):
            r = ctx.cache.refresh()
            self._json(200, {"totalGames": r.inventory["totalGames"], "etag": r.etag})

    return Handler


def make_server(host: str, port: int, ctx: Context) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), _handler_for(ctx))
    server.daemon_threads = True
    return server
