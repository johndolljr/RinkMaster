import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

from rinkmasterd import scores, server
from rinkmasterd.cache import InventoryCache
from tests.fixtures import make_tree


def write(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def make_scores_tree():
    root = tempfile.mkdtemp(prefix="scores-")
    roms = os.path.join(root, "roms")
    write(roms + "/mame-libretro/mame2003/hi/tempest.hi", b"\x01\x02\x03")
    write(roms + "/mame-libretro/mame2003/nvram/tempest.nv", b"nv")
    write(roms + "/mame-libretro/mame2010/nvram/1944.nv", b"nv2")
    write(roms + "/mame-advmame/hi/centiped.hi", b"hi")
    write(roms + "/mame-libretro/mame2003/hi/readme.txt")      # not a score file
    write(roms + "/mame-libretro/mame2003/hi/.hidden.hi")      # hidden
    write(roms + "/mame-libretro/galaga.zip")                  # a ROM, not a score
    write(roms + "/atari2600/hi/nothing.hi")                   # no such core system, still a valid layout
    return root, roms


class ListScoresTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms = make_scores_tree()
        self.addCleanup(shutil.rmtree, self.root, True)

    def test_lists_hi_and_nv_files_by_core(self):
        files = scores.list_scores(self.roms)["files"]
        got = [(f["core"], f["kind"], f["game"]) for f in files]
        self.assertEqual(got, [
            ("atari2600", "hi", "nothing"),
            ("mame-advmame", "hi", "centiped"),
            ("mame-libretro/mame2003", "hi", "tempest"),
            ("mame-libretro/mame2003", "nv", "tempest"),
            ("mame-libretro/mame2010", "nv", "1944"),
        ])

    def test_entries_carry_size_and_mtime(self):
        f = next(x for x in scores.list_scores(self.roms)["files"] if x["game"] == "tempest" and x["kind"] == "hi")
        self.assertEqual(f["size"], 3)
        self.assertGreater(f["mtime"], 0)

    def test_entries_carry_the_md5_of_the_file(self):
        import hashlib
        f = next(x for x in scores.list_scores(self.roms)["files"] if x["game"] == "tempest" and x["kind"] == "hi")
        self.assertEqual(f["md5"], hashlib.md5(b"\x01\x02\x03").hexdigest())

    def test_md5_follows_changes_and_unchanged_files_are_not_rehashed(self):
        scores.list_scores(self.roms)
        calls = []
        real = scores._md5_of
        scores._md5_of = lambda path: calls.append(path) or real(path)
        try:
            scores.list_scores(self.roms)
            self.assertEqual(calls, [])  # same size and mtime: served from the cache
            hi = self.roms + "/mame-libretro/mame2003/hi/tempest.hi"
            with open(hi, "wb") as f:
                f.write(b"NEWER")
            os.utime(hi, (1_800_000_000, 1_800_000_000))
            f = next(x for x in scores.list_scores(self.roms)["files"] if x["game"] == "tempest" and x["kind"] == "hi")
            import hashlib
            self.assertEqual(f["md5"], hashlib.md5(b"NEWER").hexdigest())
            self.assertEqual(len(calls), 1)
        finally:
            scores._md5_of = real

    def test_missing_roms_folder_gives_empty_list(self):
        self.assertEqual(scores.list_scores(os.path.join(self.root, "nope"))["files"], [])

    def test_symlinked_score_folders_are_not_listed_twice(self):
        # xarcade has arcade/advmame/hi -> mame-advmame/hi; the real folder already lists those files
        os.makedirs(os.path.join(self.roms, "arcade", "advmame"))
        os.symlink(os.path.join(self.roms, "mame-advmame", "hi"), os.path.join(self.roms, "arcade", "advmame", "hi"))
        cores = [f["core"] for f in scores.list_scores(self.roms)["files"]]
        self.assertNotIn("arcade/advmame", cores)
        self.assertEqual(cores.count("mame-advmame"), 1)

    def test_symlinked_folders_are_ignored(self):
        os.symlink("/etc", os.path.join(self.roms, "mame-libretro", "mame2099"))
        cores = {f["core"] for f in scores.list_scores(self.roms)["files"]}
        self.assertNotIn("mame-libretro/mame2099", cores)


class ReadScoreTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms = make_scores_tree()
        self.addCleanup(shutil.rmtree, self.root, True)

    def test_reads_raw_bytes(self):
        self.assertEqual(scores.read_score(self.roms, "mame-libretro/mame2003", "hi", "tempest"), b"\x01\x02\x03")
        self.assertEqual(scores.read_score(self.roms, "mame-advmame", "hi", "centiped"), b"hi")

    def test_unknown_file_is_not_found(self):
        with self.assertRaises(scores.NotFound):
            scores.read_score(self.roms, "mame-libretro/mame2003", "hi", "galaga")

    def test_bad_names_are_rejected(self):
        for core, kind, game in [("..", "hi", "x"), ("mame-libretro/../..", "hi", "x"), ("mame-libretro", "zip", "x"),
                                 ("mame-libretro/mame2003", "hi", "../x"), ("mame-libretro/mame2003", "hi", ""),
                                 ("a/b/c", "hi", "x"), ("", "hi", "x")]:
            with self.assertRaises(scores.BadRequest, msg=(core, kind, game)):
                scores.read_score(self.roms, core, kind, game)


class ScoresServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root, roms = make_scores_tree()
        tree_root, _, cfgs = make_tree()
        cls.tree_root = tree_root
        cache = InventoryCache(roms, cfgs, hostname="testbox")
        cls.httpd = server.make_server("127.0.0.1", 0, server.Context(cache=cache, version="test"))
        cls.base = "http://127.0.0.1:%d" % cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        shutil.rmtree(cls.root, True)
        shutil.rmtree(cls.tree_root, True)

    def test_list_endpoint(self):
        r = urllib.request.urlopen(self.base + "/v1/scores", timeout=5)
        data = json.loads(r.read())
        self.assertEqual(data["machine"], "testbox")
        self.assertEqual(len(data["files"]), 5)

    def test_raw_file_endpoint(self):
        r = urllib.request.urlopen(self.base + "/v1/scores/file?core=mame-libretro/mame2003&kind=hi&game=tempest", timeout=5)
        self.assertEqual(r.headers["Content-Type"], "application/octet-stream")
        self.assertEqual(r.read(), b"\x01\x02\x03")

    def test_missing_and_bad_requests(self):
        for query, code in [("core=mame-libretro/mame2003&kind=hi&game=nope", 404), ("core=..&kind=hi&game=x", 400), ("", 400)]:
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(self.base + "/v1/scores/file?" + query, timeout=5)
            self.assertEqual(cm.exception.code, code, query)

    def test_scores_are_read_only(self):
        req = urllib.request.Request(self.base + "/v1/scores", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(cm.exception.code, 405)


class WriteScoreTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms = make_scores_tree()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.hi = self.roms + "/mame-libretro/mame2003/hi/tempest.hi"

    def test_replaces_the_file_and_keeps_a_timestamped_backup(self):
        os.chmod(self.hi, 0o640)
        out = scores.write_score(self.roms, "mame-libretro/mame2003", "hi", "tempest", b"NEWDATA", now=1_700_000_000)
        self.assertEqual(open(self.hi, "rb").read(), b"NEWDATA")
        self.assertEqual(out["backup"], "tempest.hi.bak-20231114T221320Z")
        self.assertEqual(open(os.path.join(os.path.dirname(self.hi), out["backup"]), "rb").read(), b"\x01\x02\x03")
        self.assertEqual(os.stat(self.hi).st_mode & 0o777, 0o640)  # mode preserved
        self.assertEqual(out["size"], 7)

    def test_backups_do_not_show_up_as_score_files(self):
        scores.write_score(self.roms, "mame-libretro/mame2003", "hi", "tempest", b"X", now=1)
        names = [(f["core"], f["game"]) for f in scores.list_scores(self.roms)["files"] if f["kind"] == "hi"]
        self.assertEqual(names.count(("mame-libretro/mame2003", "tempest")), 1)

    def test_only_existing_hi_files_can_be_replaced(self):
        with self.assertRaises(scores.NotFound):
            scores.write_score(self.roms, "mame-libretro/mame2003", "hi", "newgame", b"x")
        with self.assertRaises(scores.BadRequest):
            scores.write_score(self.roms, "mame-libretro/mame2003", "nv", "tempest", b"x")  # NVRAM is never written

    def test_bad_names_and_sizes_are_rejected_and_nothing_changes(self):
        for core, game in [("..", "x"), ("mame-libretro/../..", "x"), ("mame-libretro/mame2003", "../x")]:
            with self.assertRaises(scores.BadRequest):
                scores.write_score(self.roms, core, "hi", game, b"x")
        for data in (b"", b"x" * (scores.MAX_SCORE_BYTES + 1)):
            with self.assertRaises(scores.BadRequest):
                scores.write_score(self.roms, "mame-libretro/mame2003", "hi", "tempest", data)
        self.assertEqual(open(self.hi, "rb").read(), b"\x01\x02\x03")

    def test_symlinked_targets_are_refused(self):
        os.symlink(self.hi, self.roms + "/mame-libretro/mame2003/hi/link.hi")
        with self.assertRaises(scores.NotFound):
            scores.write_score(self.roms, "mame-libretro/mame2003", "hi", "link", b"x")


class WriteScoreServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root, roms = make_scores_tree()
        cls.hi = roms + "/mame-libretro/mame2003/hi/tempest.hi"
        tree_root, _, cfgs = make_tree()
        cls.tree_root = tree_root
        cls.httpd = server.make_server("127.0.0.1", 0, server.Context(cache=InventoryCache(roms, cfgs, hostname="t"), version="test"))
        cls.base = "http://127.0.0.1:%d" % cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        shutil.rmtree(cls.root, True)
        shutil.rmtree(cls.tree_root, True)

    def put(self, query, body):
        req = urllib.request.Request(self.base + "/v1/scores/file?" + query, data=body, method="PUT")
        return urllib.request.urlopen(req, timeout=5)

    def test_put_writes_and_reports_the_backup(self):
        r = self.put("core=mame-libretro/mame2003&kind=hi&game=tempest", b"\x07\x08")
        data = json.loads(r.read())
        self.assertTrue(data["written"])
        self.assertTrue(data["backup"].startswith("tempest.hi.bak-"))
        self.assertEqual(open(self.hi, "rb").read(), b"\x07\x08")

    def test_put_errors(self):
        for query, body, code in [("core=mame-libretro/mame2003&kind=hi&game=nope", b"x", 404),
                                  ("core=..&kind=hi&game=x", b"x", 400),
                                  ("core=mame-libretro/mame2003&kind=hi&game=tempest", b"", 400),
                                  ("core=mame-libretro/mame2003&kind=nv&game=tempest", b"x", 400)]:
            with self.assertRaises(urllib.error.HTTPError) as cm:
                self.put(query, body)
            self.assertEqual(cm.exception.code, code, query)

    def test_oversized_body_is_refused_without_reading_it(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.put("core=mame-libretro/mame2003&kind=hi&game=tempest", b"x" * (scores.MAX_SCORE_BYTES + 1))
        self.assertEqual(cm.exception.code, 413)
