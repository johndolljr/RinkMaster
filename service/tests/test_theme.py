import io
import json
import os
import shutil
import tarfile
import threading
import unittest
import urllib.error
import urllib.request
import zipfile

from rinkmasterd import server, theme
from rinkmasterd.cache import InventoryCache
from tests.fixtures import make_tree


def _make_tar(files: dict[str, bytes]) -> bytes:
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf:
        for name, data in files.items():
            ti = tarfile.TarInfo(name=name)
            ti.size = len(data)
            ti.mtime = 1000000000
            tf.addfile(ti, io.BytesIO(data))
    return bio.getvalue()


def _make_zip(files: dict[str, bytes]) -> bytes:
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, mode="w") as zf:
        for name, data in files.items():
            zf.writestr(name, data)
    return bio.getvalue()


class ThemeLogicTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.addCleanup(lambda: shutil.rmtree(self.root, True))

    def test_validate_theme_name(self):
        self.assertEqual(theme.validate_theme_name("dll-arcade"), "dll-arcade")
        self.assertEqual(theme.validate_theme_name("rink_1984.v2"), "rink_1984.v2")
        with self.assertRaises(theme.BadRequest):
            theme.validate_theme_name("")
        with self.assertRaises(theme.BadRequest):
            theme.validate_theme_name("bad name with spaces")
        with self.assertRaises(theme.BadRequest):
            theme.validate_theme_name("../escape")
        with self.assertRaises(theme.BadRequest):
            theme.validate_theme_name("x" * 100)

    def test_detect_frontend_es(self):
        es_dir = os.path.join(self.cfgs, "all", "emulationstation")
        os.makedirs(es_dir, exist_ok=True)
        self.assertEqual(theme.detect_frontend(self.cfgs), "emulationstation")

    def test_detect_frontend_attract(self):
        attract_dir = os.path.join(self.cfgs, "all", "attractmode")
        os.makedirs(attract_dir, exist_ok=True)
        self.assertEqual(theme.detect_frontend(self.cfgs), "attract-mode")

    def test_es_theme_list_and_activate(self):
        es_dir = os.path.join(self.cfgs, "all", "emulationstation")
        themes_dir = os.path.join(es_dir, "themes")
        os.makedirs(os.path.join(themes_dir, "dll-arcade"), exist_ok=True)
        os.makedirs(os.path.join(themes_dir, "carbon"), exist_ok=True)

        status = theme.get_theme_status(self.cfgs)
        self.assertEqual(status["frontend"], "emulationstation")
        self.assertEqual(status["installedThemes"], ["carbon", "dll-arcade"])
        self.assertIsNone(status["activeTheme"])

        # Activate dll-arcade when es_settings.cfg does not exist yet
        res = theme.activate_theme(self.cfgs, "dll-arcade")
        self.assertTrue(res["changed"])
        self.assertEqual(res["activeTheme"], "dll-arcade")
        self.assertIsNone(res["previousTheme"])

        # Re-activating same theme is no-op
        res2 = theme.activate_theme(self.cfgs, "dll-arcade")
        self.assertFalse(res2["changed"])

        # Activating carbon updates es_settings.cfg and creates backup
        res3 = theme.activate_theme(self.cfgs, "carbon")
        self.assertTrue(res3["changed"])
        self.assertEqual(res3["previousTheme"], "dll-arcade")
        self.assertEqual(res3["activeTheme"], "carbon")
        self.assertTrue(os.path.isfile(res3["backup"]))

    def test_attract_theme_list_and_activate(self):
        attract_dir = os.path.join(self.cfgs, "all", "attractmode")
        layouts_dir = os.path.join(attract_dir, "layouts")
        os.makedirs(os.path.join(layouts_dir, "rink"), exist_ok=True)
        os.makedirs(os.path.join(layouts_dir, "basic"), exist_ok=True)

        status = theme.get_theme_status(self.cfgs)
        self.assertEqual(status["frontend"], "attract-mode")
        self.assertEqual(status["installedThemes"], ["basic", "rink"])

        # Activate rink in attract.cfg
        res = theme.activate_theme(self.cfgs, "rink")
        self.assertTrue(res["changed"])
        self.assertEqual(res["activeTheme"], "rink")

        # Activating basic creates backup and updates line
        res2 = theme.activate_theme(self.cfgs, "basic")
        self.assertTrue(res2["changed"])
        self.assertEqual(res2["previousTheme"], "rink")
        self.assertEqual(res2["activeTheme"], "basic")
        self.assertTrue(os.path.isfile(res2["backup"]))

    def test_install_theme_tar_and_zip(self):
        files = {
            "theme.xml": b"<theme><formatVersion>4</formatVersion></theme>",
            "art/bg.png": b"FAKEPNG1234",
        }
        tar_bytes = _make_tar(files)
        res = theme.install_theme_archive(self.cfgs, "my-theme", tar_bytes, activate=True)
        self.assertEqual(res["theme"], "my-theme")
        self.assertTrue(res["activated"])
        dest = res["destDir"]
        self.assertTrue(os.path.isfile(os.path.join(dest, "theme.xml")))
        self.assertTrue(os.path.isfile(os.path.join(dest, "art", "bg.png")))

        # Test zip
        zip_bytes = _make_zip({"layout.nut": b"fe.layout.width = 1080;"})
        res_zip = theme.install_theme_archive(self.cfgs, "zip-theme", zip_bytes, activate=False)
        self.assertFalse(res_zip["activated"])
        self.assertTrue(os.path.isfile(os.path.join(res_zip["destDir"], "layout.nut")))

    def test_install_theme_rejects_escape(self):
        evil_tar = _make_tar({"../evil.txt": b"hacked"})
        with self.assertRaises(theme.BadRequest):
            theme.install_theme_archive(self.cfgs, "bad-theme", evil_tar)

        evil_zip = _make_zip({"../../evil.txt": b"hacked"})
        with self.assertRaises(theme.BadRequest):
            theme.install_theme_archive(self.cfgs, "bad-theme-zip", evil_zip)

    def test_install_theme_rejects_corrupted(self):
        with self.assertRaises(theme.BadRequest):
            theme.install_theme_archive(self.cfgs, "corrupted", b"NOT_A_VALID_ARCHIVE")


class ThemeServerTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.cache = InventoryCache(self.roms, self.cfgs, hostname="arcadebox")
        self.httpd = server.make_server("127.0.0.1", 0, server.Context(cache=self.cache, version="test"))
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (self.httpd.shutdown(), self.httpd.server_close(), shutil.rmtree(self.root, True)))

    def call(self, method, path, body=None, raw=None, content_type="application/json"):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        headers = {"Content-Type": content_type} if data is not None else {}
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            r = urllib.request.urlopen(req, timeout=5)
            return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_server_theme_status(self):
        code, data = self.call("GET", "/v1/theme")
        self.assertEqual(code, 200)
        self.assertEqual(data["machine"], "arcadebox")
        self.assertIn("frontend", data)
        self.assertIn("installedThemes", data)

    def test_server_theme_activate(self):
        code, data = self.call("POST", "/v1/theme/activate", {"theme": "test-theme"})
        self.assertEqual(code, 200)
        self.assertEqual(data["activeTheme"], "test-theme")
        self.assertEqual(data["machine"], "arcadebox")

        # Bad theme name
        bad_code, bad_data = self.call("POST", "/v1/theme/activate", {"theme": "../evil"})
        self.assertEqual(bad_code, 400)

    def test_server_theme_install(self):
        files = {"theme.xml": b"<theme></theme>"}
        archive = _make_tar(files)
        code, data = self.call("POST", "/v1/theme/install?name=custom-theme&activate=1", raw=archive, content_type="application/octet-stream")
        self.assertEqual(code, 200)
        self.assertEqual(data["theme"], "custom-theme")
        self.assertTrue(data["activated"])
        self.assertEqual(data["machine"], "arcadebox")

        # Bad archive
        err_code, err_data = self.call("POST", "/v1/theme/install?name=broken", raw=b"badbytes", content_type="application/octet-stream")
        self.assertEqual(err_code, 400)
