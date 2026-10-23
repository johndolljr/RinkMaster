import json
import os
import shutil
import tempfile
import unittest
import urllib.error
import urllib.request
import threading
import xml.etree.ElementTree as ET

from rinkmasterd import gamelist, server
from rinkmasterd.cache import InventoryCache
from tests.fixtures import make_tree


def entry(**kw):
    base = {"path": "./Pitfall (USA).zip", "name": "Pitfall", "desc": "Jump & swing", "image": "./flyer/Pitfall (USA).png"}
    base.update(kw)
    return base


class UpsertTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.file = os.path.join(self.dir, "all", "emulationstation", "gamelists", "atari2600", "gamelist.xml")

    def games(self):
        return {g.findtext("path"): g for g in ET.parse(self.file).getroot().findall("game")}

    def test_creates_the_list_with_the_game(self):
        r = gamelist.upsert(self.dir, "atari2600", [entry()])
        self.assertEqual((r["added"], r["updated"], r["changed"], r["backup"]), (1, 0, True, None))
        g = self.games()["./Pitfall (USA).zip"]
        self.assertEqual(g.findtext("name"), "Pitfall")
        self.assertEqual(g.findtext("desc"), "Jump & swing")  # escaped on disk, intact when read back

    def test_merges_by_path_and_keeps_other_games_and_fields(self):
        gamelist.upsert(self.dir, "atari2600", [entry(), entry(path="./Other.zip", name="Other")])
        with open(self.file) as f:
            before = f.read()
        r = gamelist.upsert(self.dir, "atari2600", [entry(name="Pitfall!", video="./snap/Pitfall (USA).mp4")])
        self.assertEqual((r["added"], r["updated"]), (0, 1))
        self.assertEqual(r["backup"], self.file + ".bak")
        with open(self.file + ".bak") as f:
            self.assertEqual(f.read(), before)
        games = self.games()
        self.assertEqual(games["./Pitfall (USA).zip"].findtext("name"), "Pitfall!")
        self.assertEqual(games["./Pitfall (USA).zip"].findtext("image"), "./flyer/Pitfall (USA).png")
        self.assertEqual(games["./Other.zip"].findtext("name"), "Other")

    def test_same_entries_again_is_a_no_op(self):
        gamelist.upsert(self.dir, "atari2600", [entry()])
        r = gamelist.upsert(self.dir, "atari2600", [entry()])
        self.assertFalse(r["changed"])
        self.assertFalse(os.path.exists(self.file + ".bak"))

    def test_dry_run_writes_nothing(self):
        r = gamelist.upsert(self.dir, "atari2600", [entry()], dry_run=True)
        self.assertTrue(r["changed"] and r["dryRun"])
        self.assertFalse(os.path.exists(self.file))

    def test_existing_game_gets_new_fields_added(self):
        os.makedirs(os.path.dirname(self.file))
        with open(self.file, "w") as f:
            f.write("<gameList><game><path>./Pitfall (USA).zip</path><name>Old</name></game></gameList>")
        r = gamelist.upsert(self.dir, "atari2600", [entry(genre="Platform")])
        self.assertEqual((r["added"], r["updated"]), (0, 1))
        self.assertEqual(self.games()["./Pitfall (USA).zip"].findtext("genre"), "Platform")

    def test_rejects_bad_input(self):
        for system in (None, "../x", "a/b", ""):
            with self.assertRaises(gamelist.BadRequest):
                gamelist.upsert(self.dir, system, [entry()])
        for games in (None, [], "x", [1], [{"name": "x"}], [entry(path="Pitfall.zip")], [entry(path="./../x.zip")],
                      [entry(image="/etc/passwd")], [entry(image="./../x.png")], [entry(name=5)], [entry(desc="x" * 9000)]):
            with self.assertRaises(gamelist.BadRequest, msg=repr(games)[:60]):
                gamelist.upsert(self.dir, "atari2600", games)
        self.assertFalse(os.path.exists(self.file))

    def test_unreadable_existing_list_is_left_alone(self):
        os.makedirs(os.path.dirname(self.file))
        with open(self.file, "w") as f:
            f.write("<gameList><game>")
        with self.assertRaises(gamelist.BadRequest):
            gamelist.upsert(self.dir, "atari2600", [entry()])
        with open(self.file) as f:
            self.assertEqual(f.read(), "<gameList><game>")

    def test_keeps_the_file_mode(self):
        gamelist.upsert(self.dir, "atari2600", [entry()])
        os.chmod(self.file, 0o600)
        gamelist.upsert(self.dir, "atari2600", [entry(name="Changed")])
        self.assertEqual(os.stat(self.file).st_mode & 0o777, 0o600)

    def test_failed_write_leaves_no_temp_file(self):
        from unittest import mock
        gamelist.upsert(self.dir, "atari2600", [entry()])
        with mock.patch.object(gamelist.os, "replace", side_effect=OSError("disk")):
            with self.assertRaises(OSError):
                gamelist.upsert(self.dir, "atari2600", [entry(name="Changed")])
        self.assertEqual([f for f in os.listdir(os.path.dirname(self.file)) if f.startswith(".gamelist-")], [])


class GamelistEndpointTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        cache = InventoryCache(self.roms, self.cfgs, hostname="testbox")
        self.httpd = server.make_server("127.0.0.1", 0, server.Context(cache=cache, version="test"))
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (self.httpd.shutdown(), self.httpd.server_close(), shutil.rmtree(self.root, True)))

    def post(self, path, body, raw=None):
        data = raw if raw is not None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method="POST", headers={"Content-Type": "application/json"})
        try:
            r = urllib.request.urlopen(req, timeout=10)
            return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_upsert_and_dry_run(self):
        body = {"system": "snes", "games": [entry()]}
        code, data = self.post("/v1/gamelist?dryRun=1", body)
        self.assertEqual((code, data["added"], data["dryRun"]), (200, 1, True))
        self.assertFalse(os.path.exists(data["file"]))
        code, data = self.post("/v1/gamelist", body)
        self.assertTrue(os.path.exists(data["file"]))

    def test_errors(self):
        self.assertEqual(self.post("/v1/gamelist", {"system": "../x", "games": [entry()]})[0], 400)
        self.assertEqual(self.post("/v1/gamelist", None, raw=b"nope")[0], 400)
        from unittest import mock
        with mock.patch.object(server, "MAX_GAMELIST_BODY", 1000):
            self.assertEqual(self.post("/v1/gamelist", None, raw=b"x" * 1001)[0], 413)


class MediaAndMissingTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.cfgs = os.path.join(self.dir, "configs")
        self.roms = os.path.join(self.dir, "roms")
        self.file = os.path.join(self.cfgs, "all", "emulationstation", "gamelists", "mame-libretro", "gamelist.xml")
        for rel in ("flyer/galaga.png", "snap/galaga.mp4", "snap/galaga.png", "wheel/galaga.png", "snap/pacman.png", "boxart/lair.jpg"):
            p = os.path.join(self.roms, "mame-libretro", rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").close()

    def game(self, path):
        return {g.findtext("path"): g for g in ET.parse(self.file).getroot().findall("game")}[path]

    def test_media_is_found_beside_the_rom(self):
        found = gamelist.find_media(self.roms, "mame-libretro", "./galaga.zip")
        self.assertEqual(found, {"image": "./flyer/galaga.png", "marquee": "./wheel/galaga.png", "thumbnail": "./snap/galaga.png"})
        self.assertEqual(gamelist.find_media(self.roms, "mame-libretro", "./pacman.zip"), {"thumbnail": "./snap/pacman.png"})
        self.assertEqual(gamelist.find_media(self.roms, "mame-libretro", "./lair.daphne"), {"image": "./boxart/lair.jpg"})
        self.assertEqual(gamelist.find_media(self.roms, "mame-libretro", "./none.zip"), {})

    def test_auto_media_fills_only_what_exists_and_keeps_given_paths(self):
        gamelist.upsert(self.cfgs, "mame-libretro", [{"path": "./galaga.zip", "name": "Galaga", "image": "./custom.png"},
                                                    {"path": "./none.zip", "name": "None"}], roms=self.roms, auto_media=True)
        g = self.game("./galaga.zip")
        self.assertEqual((g.findtext("image"), g.findtext("thumbnail")), ("./custom.png", "./snap/galaga.png"))
        self.assertIsNone(g.find("video"))
        self.assertIsNone(self.game("./none.zip").find("image"))

    def test_only_missing_keeps_existing_values_and_fills_gaps(self):
        os.makedirs(os.path.dirname(self.file))
        with open(self.file, "w") as f:
            f.write("<gameList><game><path>./galaga.zip</path><name>Scraped Name</name><desc></desc></game></gameList>")
        r = gamelist.upsert(self.cfgs, "mame-libretro", [{"path": "./galaga.zip", "name": "Galaga", "desc": "Shoot.", "developer": "Namco",
                                                         "genre": ""}], only_missing=True)
        g = self.game("./galaga.zip")
        self.assertEqual((g.findtext("name"), g.findtext("desc"), g.findtext("developer")), ("Scraped Name", "Shoot.", "Namco"))
        self.assertIsNone(g.find("genre"))  # an empty value is never written when only filling gaps
        self.assertEqual((r["added"], r["updated"]), (0, 1))
        again = gamelist.upsert(self.cfgs, "mame-libretro", [{"path": "./galaga.zip", "name": "Other", "desc": "Different"}], only_missing=True)
        self.assertFalse(again["changed"])

    def test_endpoint_takes_the_flags_and_big_batches(self):
        root, roms, cfgs = make_tree()
        self.addCleanup(shutil.rmtree, root, True)
        cache = InventoryCache(roms, cfgs, hostname="t")
        httpd = server.make_server("127.0.0.1", 0, server.Context(cache=cache, version="t"))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (httpd.shutdown(), httpd.server_close()))
        os.makedirs(os.path.join(roms, "mame-libretro", "flyer"), exist_ok=True)
        open(os.path.join(roms, "mame-libretro", "flyer", "galaga.png"), "w").close()
        games = [{"path": "./g%d.zip" % i, "name": "G", "desc": "d" * 1000} for i in range(100)] + [{"path": "./galaga.zip", "name": "Galaga"}]
        req = urllib.request.Request("http://127.0.0.1:%d/v1/gamelist" % httpd.server_address[1], method="POST",
                                     data=json.dumps({"system": "mame-libretro", "games": games, "autoMedia": True, "onlyMissing": True}).encode())
        data = json.loads(urllib.request.urlopen(req, timeout=10).read())
        self.assertEqual(data["added"], 101)
        g = {x.findtext("path"): x for x in ET.parse(data["file"]).getroot().findall("game")}["./galaga.zip"]
        self.assertEqual(g.findtext("image"), "./flyer/galaga.png")


class HiddenTests(unittest.TestCase):
    def test_a_game_can_be_hidden(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        r = gamelist.upsert(d, "mame-libretro", [{"path": "./sfiii3.zip", "hidden": "true"}])
        self.assertEqual(r["added"], 1)
        g = ET.parse(r["file"]).getroot().find("game")
        self.assertEqual((g.findtext("path"), g.findtext("hidden")), ("./sfiii3.zip", "true"))
