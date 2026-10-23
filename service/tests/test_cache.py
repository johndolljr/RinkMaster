import os
import shutil
import unittest

from rinkmasterd.cache import InventoryCache
from tests.fixtures import make_tree, write


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.cache = InventoryCache(self.roms, self.cfgs, hostname="testbox")

    def test_first_get_is_a_miss_second_is_a_hit(self):
        first = self.cache.get()
        second = self.cache.get()
        self.assertFalse(first.hit)
        self.assertTrue(second.hit)
        self.assertEqual(first.etag, second.etag)
        self.assertEqual(first.body, second.body)

    def test_body_is_json_with_machine_and_generated_at(self):
        import json
        data = json.loads(self.cache.get().body)
        self.assertEqual(data["machine"], "testbox")
        self.assertIn("generatedAt", data)
        self.assertEqual(data["totalGames"], 4)

    def test_adding_a_rom_invalidates_the_cache_and_changes_the_etag(self):
        before = self.cache.get()
        write(os.path.join(self.roms, "mame-libretro", "1942.zip"))
        bump = os.stat(os.path.join(self.roms, "mame-libretro")).st_mtime_ns + 5_000_000_000
        os.utime(os.path.join(self.roms, "mame-libretro"), ns=(bump, bump))
        after = self.cache.get()
        self.assertFalse(after.hit)
        self.assertNotEqual(before.etag, after.etag)
        self.assertEqual(after.inventory["totalGames"], 5)

    def test_changing_a_config_invalidates_the_cache(self):
        self.cache.get()
        path = os.path.join(self.cfgs, "all", "emulators.cfg")
        write(path, b'mame-libretro_galaga = "lr-mame2016"\n')
        bump = os.stat(path).st_mtime_ns + 5_000_000_000
        os.utime(path, ns=(bump, bump))
        after = self.cache.get()
        self.assertFalse(after.hit)
        galaga = next(g for s in after.inventory["systems"] if s["name"] == "mame-libretro" for g in s["games"] if g["name"] == "galaga")
        self.assertEqual(galaga["emulator"], "lr-mame2016")

    def test_forced_refresh_rebuilds_but_keeps_etag_for_same_content(self):
        before = self.cache.get()
        refreshed = self.cache.refresh()
        self.assertFalse(refreshed.hit)
        self.assertEqual(before.etag, refreshed.etag)  # etag covers content, not generatedAt


if __name__ == "__main__":
    unittest.main()


class TtlTests(unittest.TestCase):
    def test_zero_max_age_always_rebuilds(self):
        root, roms, cfgs = make_tree()
        self.addCleanup(shutil.rmtree, root, True)
        cache = InventoryCache(roms, cfgs, hostname="t", max_age=-1)
        self.assertFalse(cache.get().hit)
        self.assertFalse(cache.get().hit)


class MissingPathsTests(unittest.TestCase):
    def test_missing_roms_and_configs_give_an_empty_inventory(self):
        cache = InventoryCache("/nonexistent/roms", "/nonexistent/configs", hostname="t")
        self.assertEqual(cache.signature(), ())
        r = cache.get()
        self.assertEqual(r.inventory["totalGames"], 0)
        self.assertTrue(cache.get().hit)
