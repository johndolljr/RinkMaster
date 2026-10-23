import json
import os
import shutil
import threading
import unittest
import urllib.error
import urllib.request

from rinkmasterd import server
from rinkmasterd.cache import InventoryCache
from tests.fixtures import make_tree


class EmulatorManagementServerTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.cache = InventoryCache(self.roms, self.cfgs, hostname="testbox")
        self.httpd = server.make_server("127.0.0.1", 0, server.Context(cache=self.cache, version="test"))
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (self.httpd.shutdown(), self.httpd.server_close(), shutil.rmtree(self.root, True)))

    def call(self, method, path, body=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(self.base + path, data=data, method=method)
        try:
            r = urllib.request.urlopen(req, timeout=5)
            return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def read(self, *parts):
        with open(os.path.join(self.cfgs, *parts)) as f:
            return f.read()

    def test_list_includes_ids_and_default(self):
        code, data = self.call("GET", "/v1/emulators")
        self.assertEqual(code, 200)
        mame = next(s for s in data["systems"] if s["name"] == "mame-libretro")
        self.assertEqual(mame["defaultEmulator"], "lr-mame2010")
        self.assertEqual([e["id"] for e in mame["emulators"]], ["lr-mame2003", "lr-mame2010"])

    def test_set_default_post_and_put(self):
        for method, emu in (("POST", "lr-mame2003"), ("PUT", "lr-mame2010")):
            code, data = self.call(method, "/v1/emulators/default", {"system": "mame-libretro", "emulator": emu})
            self.assertEqual(code, 200)
            self.assertEqual(data["emulator"], emu)
            self.assertTrue(data["changed"])
            self.assertFalse(data["dryRun"])
            self.assertEqual(data["machine"], "testbox")
        self.assertIn('default = "lr-mame2010"', self.read("mame-libretro", "emulators.cfg"))

    def test_set_default_dry_run_query(self):
        before = self.read("mame-libretro", "emulators.cfg")
        code, data = self.call("POST", "/v1/emulators/default?dryRun=1", {"system": "mame-libretro", "emulator": "lr-mame2003"})
        self.assertEqual(code, 200)
        self.assertTrue(data["dryRun"])
        self.assertEqual(self.read("mame-libretro", "emulators.cfg"), before)

    def test_set_default_refreshes_inventory(self):
        self.cache.get()
        self.call("POST", "/v1/emulators/default", {"system": "mame-libretro", "emulator": "lr-mame2003"})
        inv = json.loads(self.cache.get().body)
        galaga = next(g for s in inv["systems"] if s["name"] == "mame-libretro" for g in s["games"] if g["name"] == "galaga")
        self.assertEqual(galaga["emulator"], "lr-mame2003")

    def test_set_default_errors(self):
        self.assertEqual(self.call("POST", "/v1/emulators/default", {"system": "mame-libretro", "emulator": "nope"})[0], 400)
        self.assertEqual(self.call("POST", "/v1/emulators/default", {"system": "nosuch", "emulator": "x"})[0], 404)
        code, data = self.call("POST", "/v1/emulators/default", {"system": "../x", "emulator": "x"})
        self.assertEqual(code, 400)
        self.assertIn("error", data)

    def test_malformed_bodies(self):
        for raw in (b"", b"not json", b"[1,2]", b'"str"', b"\xff\xfe"):
            code, data = self.call("POST", "/v1/emulators/default", raw=raw)
            self.assertEqual(code, 400, raw)
            self.assertIn("error", data)
        self.assertEqual(self.call("POST", "/v1/emulators/pin", raw=b"{")[0], 400)

    def test_oversized_body_is_413(self):
        code, _ = self.call("POST", "/v1/emulators/default", raw=b" " * (70 * 1024))
        self.assertEqual(code, 413)

    def test_pin_set_and_clear(self):
        code, data = self.call("POST", "/v1/emulators/pin", {"system": "mame-libretro", "game": "galaga", "emulator": "lr-mame2003"})
        self.assertEqual(code, 200)
        self.assertEqual(data["key"], "mame-libretro_galaga")
        self.assertIn('mame-libretro_galaga = "lr-mame2003"', self.read("all", "emulators.cfg"))
        inv = json.loads(self.cache.get().body)
        galaga = next(g for s in inv["systems"] if s["name"] == "mame-libretro" for g in s["games"] if g["name"] == "galaga")
        self.assertTrue(galaga["isPinned"])
        code, data = self.call("PUT", "/v1/emulators/pin", {"system": "mame-libretro", "game": "galaga", "emulator": None})
        self.assertEqual(code, 200)
        self.assertNotIn("galaga", self.read("all", "emulators.cfg"))
        self.assertFalse(data["changed"] and data["emulator"])

    def test_pin_clear_via_delete_and_dry_run(self):
        before = self.read("all", "emulators.cfg")
        code, data = self.call("DELETE", "/v1/emulators/pin?system=mame-libretro&game=tempest&dryRun=1")
        self.assertEqual(code, 200)
        self.assertTrue(data["dryRun"])
        self.assertEqual(self.read("all", "emulators.cfg"), before)
        code, data = self.call("DELETE", "/v1/emulators/pin?system=mame-libretro&game=tempest")
        self.assertEqual(code, 200)
        self.assertTrue(data["changed"])
        self.assertNotIn("tempest", self.read("all", "emulators.cfg"))
        self.assertFalse(self.call("DELETE", "/v1/emulators/pin?system=mame-libretro&game=tempest")[1]["changed"])

    def test_empty_emulator_string_clears_the_pin(self):
        code, data = self.call("POST", "/v1/emulators/pin", {"system": "mame-libretro", "game": "tempest", "emulator": ""})
        self.assertEqual(code, 200)
        self.assertTrue(data["changed"])
        self.assertNotIn("tempest", self.read("all", "emulators.cfg"))

    def test_pin_errors(self):
        body = {"system": "mame-libretro", "game": "galaga", "emulator": "daphne"}
        self.assertEqual(self.call("POST", "/v1/emulators/pin", body)[0], 400)
        self.assertEqual(self.call("POST", "/v1/emulators/pin", dict(body, system="nosuch"))[0], 404)
        self.assertEqual(self.call("POST", "/v1/emulators/pin", dict(body, game="../x", emulator="lr-mame2003"))[0], 400)
        self.assertEqual(self.call("POST", "/v1/emulators/pin", {"system": "mame-libretro"})[0], 400)

    def test_wrong_methods(self):
        self.assertEqual(self.call("GET", "/v1/emulators/default")[0], 405)
        self.assertEqual(self.call("GET", "/v1/emulators/pin")[0], 405)
        self.assertEqual(self.call("DELETE", "/v1/emulators/default")[0], 405)
        self.assertEqual(self.call("POST", "/v1/emulators")[0], 405)


if __name__ == "__main__":
    unittest.main()
