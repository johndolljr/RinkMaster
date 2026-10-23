import shutil
import unittest

from rinkmasterd import inventory
from tests.fixtures import make_tree


class EmulatorsConfigTests(unittest.TestCase):
    def test_parse_default_ids_and_quotes(self):
        cfg = inventory.parse_emulators_cfg(
            'lr-mame2003 = "a %ROM%"\ndefault = "lr-mame2010"\n# comment\n\nbogus line\nstella = "s -x=1 %ROM%"\n')
        self.assertEqual(cfg.get("default"), "lr-mame2010")
        self.assertEqual(cfg["stella"], "s -x=1 %ROM%")
        self.assertEqual(inventory.emulator_ids(cfg), ["lr-mame2003", "stella"])

    def test_empty(self):
        self.assertEqual(inventory.parse_emulators_cfg(""), {})


class GameFilterTests(unittest.TestCase):
    def test_zip_systems_only_take_zips(self):
        self.assertEqual(inventory.game_for("mame-libretro", "f", "galaga.zip"), ("galaga", "galaga.zip"))
        self.assertIsNone(inventory.game_for("mame-libretro", "f", "galaga.zip.cfg"))
        self.assertIsNone(inventory.game_for("mame-libretro", "d", "snap"))
        self.assertIsNone(inventory.game_for("mame-libretro", "f", ".hidden.zip"))

    def test_daphne_takes_daphne_folders(self):
        self.assertEqual(inventory.game_for("daphne", "d", "lair.daphne"), ("lair", "lair.daphne"))
        self.assertIsNone(inventory.game_for("daphne", "d", "roms"))
        self.assertIsNone(inventory.game_for("daphne", "f", "x.daphne"))

    def test_other_systems_skip_notes_art_and_states(self):
        self.assertEqual(inventory.game_for("atari2600", "f", "Adventure.bin"), ("Adventure", "Adventure.bin"))
        self.assertIsNone(inventory.game_for("atari2600", "f", "notes.txt"))
        self.assertIsNone(inventory.game_for("atari2600", "f", "mk2.state1"))
        self.assertIsNone(inventory.game_for("atari2600", "d", "snap"))


class BuildInventoryTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.inv = inventory.build_inventory(self.roms, self.cfgs)

    def system(self, name):
        return next(s for s in self.inv["systems"] if s["name"] == name)

    def test_systems_sorted_and_empty_ones_omitted(self):
        self.assertEqual([s["name"] for s in self.inv["systems"]], ["atari2600", "daphne", "mame-libretro"])
        self.assertEqual(self.inv["totalGames"], 4)

    def test_mame_games_and_emulators(self):
        mame = self.system("mame-libretro")
        self.assertEqual([g["name"] for g in mame["games"]], ["galaga", "tempest"])
        self.assertEqual(mame["defaultEmulator"], "lr-mame2010")
        self.assertEqual(mame["emulators"], ["lr-mame2003", "lr-mame2010"])
        galaga, tempest = mame["games"]
        self.assertEqual((galaga["emulator"], galaga["isPinned"]), ("lr-mame2010", False))
        self.assertEqual((tempest["emulator"], tempest["isPinned"]), ("lr-mame2003", True))
        self.assertEqual(galaga["file"], "galaga.zip")

    def test_game_has_size_and_mtime(self):
        galaga = self.system("mame-libretro")["games"][0]
        self.assertEqual(galaga["size"], len(b"zipdata"))
        self.assertIsInstance(galaga["mtime"], int)

    def test_daphne_and_pinned_atari(self):
        self.assertEqual([g["name"] for g in self.system("daphne")["games"]], ["lair"])
        adv = self.system("atari2600")["games"][0]
        self.assertEqual((adv["emulator"], adv["isPinned"]), ("stella", True))

    def test_missing_roms_dir_gives_empty_inventory(self):
        inv = inventory.build_inventory(self.roms + "-nope", self.cfgs)
        self.assertEqual(inv["systems"], [])
        self.assertEqual(inv["totalGames"], 0)

    def test_game_without_any_emulator_is_none(self):
        shutil.rmtree(self.cfgs)
        inv = inventory.build_inventory(self.roms, self.cfgs)
        mame = next(s for s in inv["systems"] if s["name"] == "mame-libretro")
        self.assertIsNone(mame["games"][0]["emulator"])


if __name__ == "__main__":
    unittest.main()


class OddEntriesTests(unittest.TestCase):
    def test_symlinks_and_special_files_are_ignored(self):
        import os
        root, roms, cfgs = make_tree()
        self.addCleanup(shutil.rmtree, root, True)
        folder = os.path.join(roms, "mame-libretro")
        os.symlink(os.path.join(folder, "galaga.zip"), os.path.join(folder, "link.zip"))
        os.mkfifo(os.path.join(folder, "pipe.zip"))
        inv = inventory.build_inventory(roms, cfgs)
        names = [g["name"] for s in inv["systems"] if s["name"] == "mame-libretro" for g in s["games"]]
        self.assertEqual(names, ["galaga", "tempest"])
