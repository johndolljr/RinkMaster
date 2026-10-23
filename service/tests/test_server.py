import json
import shutil
import threading
import unittest
import urllib.error
import urllib.request

from rinkmasterd import server
from rinkmasterd.cache import InventoryCache
from tests.fixtures import make_tree


class ClientAllowTests(unittest.TestCase):
    def test_private_and_loopback_allowed(self):
        for ip in ("127.0.0.1", "192.168.6.10", "10.1.2.3", "172.16.5.5", "::1", "::ffff:192.168.1.5", "fe80::1"):
            self.assertTrue(server.is_allowed_client(ip), ip)

    def test_public_and_garbage_rejected(self):
        for ip in ("8.8.8.8", "1.1.1.1", "2001:4860:4860::8888", "not-an-ip", ""):
            self.assertFalse(server.is_allowed_client(ip), ip)


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root, roms, cfgs = make_tree()
        cache = InventoryCache(roms, cfgs, hostname="testbox")
        cls.httpd = server.make_server("127.0.0.1", 0, server.Context(cache=cache, version="test"))
        cls.base = "http://127.0.0.1:%d" % cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        shutil.rmtree(cls.root, True)

    def get(self, path, headers=None):
        req = urllib.request.Request(self.base + path, headers=headers or {})
        return urllib.request.urlopen(req, timeout=5)

    def test_health(self):
        data = json.loads(self.get("/health").read())
        self.assertTrue(data["ok"])
        self.assertEqual(data["version"], "test")
        self.assertEqual(data["machine"], "testbox")

    def test_inventory_json_etag_and_cache_header(self):
        r = self.get("/v1/inventory")
        self.assertEqual(r.status, 200)
        self.assertEqual(r.headers["Content-Type"], "application/json")
        data = json.loads(r.read())
        self.assertEqual(data["totalGames"], 4)
        etag = r.headers["ETag"]
        self.assertTrue(etag)
        second = self.get("/v1/inventory")
        self.assertEqual(second.headers["X-Cache"], "hit")

    def test_if_none_match_gives_304(self):
        etag = self.get("/v1/inventory").headers["ETag"]
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.get("/v1/inventory", {"If-None-Match": etag})
        self.assertEqual(cm.exception.code, 304)

    def test_refresh_post(self):
        req = urllib.request.Request(self.base + "/v1/refresh", method="POST")
        data = json.loads(urllib.request.urlopen(req, timeout=5).read())
        self.assertEqual(data["totalGames"], 4)

    def test_unknown_path_is_404_json(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.get("/nope")
        self.assertEqual(cm.exception.code, 404)
        self.assertIn("error", json.loads(cm.exception.read()))

    def test_head_returns_headers_without_a_body(self):
        req = urllib.request.Request(self.base + "/v1/inventory", method="HEAD")
        r = urllib.request.urlopen(req, timeout=5)
        self.assertEqual(r.status, 200)
        self.assertTrue(r.headers["ETag"])
        self.assertEqual(r.read(), b"")

    def test_non_private_client_gets_403(self):
        from unittest import mock
        with mock.patch.object(server, "is_allowed_client", return_value=False):
            with self.assertRaises(urllib.error.HTTPError) as cm:
                self.get("/health")
        self.assertEqual(cm.exception.code, 403)

    def test_wrong_method_is_405(self):
        req = urllib.request.Request(self.base + "/v1/inventory", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(cm.exception.code, 405)


if __name__ == "__main__":
    unittest.main()


class ActionServerTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        cache = InventoryCache(self.roms, self.cfgs, hostname="testbox")
        self.httpd = server.make_server("127.0.0.1", 0, server.Context(cache=cache, version="test"))
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (self.httpd.shutdown(), self.httpd.server_close(), shutil.rmtree(self.root, True)))

    def call(self, method, path):
        req = urllib.request.Request(self.base + path, method=method)
        try:
            r = urllib.request.urlopen(req, timeout=5)
            return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_delete_dry_run_returns_plan_and_deletes_nothing(self):
        import os
        code, data = self.call("DELETE", "/v1/games/mame-libretro/galaga?dryRun=1&withArt=1")
        self.assertEqual(code, 200)
        self.assertTrue(data["dryRun"])
        self.assertIn("mame-libretro/galaga.zip", data["remove"])
        self.assertTrue(os.path.exists(os.path.join(self.roms, "mame-libretro", "galaga.zip")))

    def test_delete_removes_and_refreshes_the_inventory(self):
        import os
        code, data = self.call("DELETE", "/v1/games/mame-libretro/galaga?withArt=1")
        self.assertEqual(code, 200)
        self.assertFalse(data["dryRun"])
        self.assertFalse(os.path.exists(os.path.join(self.roms, "mame-libretro", "galaga.zip")))
        code, inv = self.call("GET", "/v1/inventory")
        names = [g["name"] for s in inv["systems"] if s["name"] == "mame-libretro" for g in s["games"]]
        self.assertEqual(names, ["tempest"])

    def test_delete_unknown_game_is_404_and_bad_name_is_400(self):
        self.assertEqual(self.call("DELETE", "/v1/games/mame-libretro/nosuch")[0], 404)
        self.assertEqual(self.call("DELETE", "/v1/games/mame-libretro/..%2Fgalaga")[0], 400)
        self.assertEqual(self.call("DELETE", "/v1/games/mame-libretro/.hidden")[0], 400)

    def test_games_route_only_accepts_delete(self):
        self.assertEqual(self.call("GET", "/v1/games/mame-libretro/galaga")[0], 405)
        self.assertEqual(self.call("DELETE", "/v1/games/onlyonepart")[0], 404)

    def test_emulators_endpoint_reports_installed_flags(self):
        from tests.fixtures import make_emulators
        cache = InventoryCache(self.roms, make_emulators(self.root), hostname="testbox")
        httpd = server.make_server("127.0.0.1", 0, server.Context(cache=cache, version="test"))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (httpd.shutdown(), httpd.server_close()))
        r = urllib.request.urlopen("http://127.0.0.1:%d/v1/emulators" % httpd.server_address[1], timeout=5)
        data = json.loads(r.read())
        self.assertEqual(data["machine"], "testbox")
        flags = {s["name"]: s["hasInstalledEmulator"] for s in data["systems"]}
        self.assertEqual(flags, {"atari2600": False, "daphne": True, "mame-libretro": True})


class FrontendServerTests(unittest.TestCase):
    def setUp(self):
        from tests.test_frontend import make_attract
        self.root, self.roms, self.cfgs = make_tree()
        self.log = self.root + "/attract.log"
        self.fake = make_attract(self.root, self.cfgs, self.log)
        cache = InventoryCache(self.roms, self.cfgs, hostname="testbox")
        ctx = server.Context(cache=cache, version="test", attract_bin=self.fake)
        self.httpd = server.make_server("127.0.0.1", 0, ctx)
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (self.httpd.shutdown(), self.httpd.server_close(), shutil.rmtree(self.root, True)))

    def call(self, method, path):
        req = urllib.request.Request(self.base + path, method=method)
        try:
            r = urllib.request.urlopen(req, timeout=10)
            return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_frontend_refresh_endpoint(self):
        code, data = self.call("POST", "/v1/frontend/refresh?system=mame-libretro")
        self.assertEqual(code, 200)
        self.assertEqual(data["refreshed"], ["Multiple Arcade Machine Emulator"])

    def test_frontend_refresh_validates_the_system(self):
        self.assertEqual(self.call("POST", "/v1/frontend/refresh")[0], 400)
        self.assertEqual(self.call("POST", "/v1/frontend/refresh?system=..%2Fx")[0], 400)

    def test_frontend_restart_endpoint_rebuilds_attract_lists(self):
        code, data = self.call("POST", "/v1/frontend/restart")
        self.assertEqual(code, 200)
        self.assertEqual(data["frontend"], "attract-mode")
        self.assertEqual(len(data["refreshed"]), 3)

    def test_frontend_restart_busy_is_a_409(self):
        from unittest import mock
        with mock.patch.object(server.frontend, "restart", side_effect=server.frontend.Busy("a game is running")):
            code, data = self.call("POST", "/v1/frontend/restart?force=0")
        self.assertEqual((code, data["error"]), (409, "a game is running"))

    def test_frontend_restart_passes_force(self):
        from unittest import mock
        with mock.patch.object(server.frontend, "restart", return_value={"frontend": "emulationstation"}) as m:
            self.call("POST", "/v1/frontend/restart?force=1")
        self.assertTrue(m.call_args.kwargs["force"])

    def test_delete_also_refreshes_the_frontend_list(self):
        code, data = self.call("DELETE", "/v1/games/mame-libretro/galaga")
        self.assertEqual(code, 200)
        self.assertEqual(data["frontend"]["refreshed"], ["Multiple Arcade Machine Emulator"])
        with open(self.log) as f:
            self.assertIn("--build-romlist", f.read())

    def test_dry_run_delete_does_not_touch_the_frontend(self):
        import os
        self.call("DELETE", "/v1/games/mame-libretro/galaga?dryRun=1")
        self.assertFalse(os.path.exists(self.log))
