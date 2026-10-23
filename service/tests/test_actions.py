import os
import shutil
import unittest

from rinkmasterd import actions
from tests.fixtures import make_tree


def write_bytes(path, data):
    with open(path, "wb") as f:
        f.write(data)


def read_text(path):
    with open(path) as f:
        return f.read()


class RemovalTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)

    def rel(self, plan):
        return sorted(plan["remove"])

    def test_rom_only_by_default_plus_pin_flag(self):
        plan = actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "galaga")
        self.assertEqual(self.rel(plan), ["mame-libretro/galaga.zip"])
        self.assertFalse(plan["pin"])  # galaga has no per-game pin

    def test_with_art_adds_art_files_in_every_art_dir(self):
        plan = actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "galaga", with_art=True)
        self.assertEqual(self.rel(plan), [
            "mame-libretro/flyer/galaga.png", "mame-libretro/galaga.zip", "mame-libretro/marquee/galaga.png",
            "mame-libretro/snap/galaga.mp4", "mame-libretro/snap/galaga.png", "mame-libretro/wheel/galaga.png"])

    def test_with_saves_adds_config_states_and_core_cfg_but_not_scores(self):
        plan = actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "galaga", with_saves=True)
        self.assertEqual(self.rel(plan), [
            "mame-libretro/galaga.state", "mame-libretro/galaga.zip", "mame-libretro/galaga.zip.cfg",
            "mame-libretro/mame2010/cfg/galaga.cfg"])

    def test_with_scores_adds_hi_and_nvram_only_when_asked(self):
        plan = actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "galaga", with_scores=True)
        self.assertEqual(self.rel(plan), [
            "mame-libretro/galaga.zip", "mame-libretro/mame2010/hi/galaga.hi", "mame-libretro/mame2010/nvram/galaga.nv"])

    def test_pinned_game_reports_pin(self):
        plan = actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "tempest")
        self.assertTrue(plan["pin"])

    def test_dry_run_changes_nothing(self):
        plan = actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "galaga", with_art=True, with_saves=True)
        before = sorted(os.listdir(os.path.join(self.roms, "mame-libretro")))
        # planning alone never deletes
        self.assertEqual(sorted(os.listdir(os.path.join(self.roms, "mame-libretro"))), before)
        self.assertTrue(os.path.exists(os.path.join(self.roms, "mame-libretro", "galaga.zip")))
        self.assertGreater(len(plan["remove"]), 1)

    def test_apply_removes_exactly_the_planned_files_and_the_pin(self):
        plan = actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "tempest", with_art=True)
        removed = actions.apply_removal(self.roms, self.cfgs, "mame-libretro", "tempest", plan)
        self.assertEqual(sorted(removed), self.rel(plan))
        self.assertFalse(os.path.exists(os.path.join(self.roms, "mame-libretro", "tempest.zip")))
        self.assertFalse(os.path.exists(os.path.join(self.roms, "mame-libretro", "marquee", "tempest.png")))
        # other games untouched
        self.assertTrue(os.path.exists(os.path.join(self.roms, "mame-libretro", "galaga.zip")))
        self.assertTrue(os.path.exists(os.path.join(self.roms, "mame-libretro", "snap", "galaga.png")))
        pins = read_text(os.path.join(self.cfgs, "all", "emulators.cfg"))
        self.assertNotIn("mame-libretro_tempest", pins)
        self.assertIn("atari2600_Adventure", pins)  # other pins preserved

    def test_daphne_folder_game_is_removed_recursively(self):
        os.makedirs(os.path.join(self.roms, "daphne", "lair.daphne"), exist_ok=True)
        with open(os.path.join(self.roms, "daphne", "lair.daphne", "lair.m2v"), "wb") as f:
            f.write(b"x")
        plan = actions.plan_removal(self.roms, self.cfgs, "daphne", "lair")
        actions.apply_removal(self.roms, self.cfgs, "daphne", "lair", plan)
        self.assertFalse(os.path.exists(os.path.join(self.roms, "daphne", "lair.daphne")))
        self.assertTrue(os.path.isdir(os.path.join(self.roms, "daphne", "roms")))

    def test_unknown_game_raises_not_found(self):
        with self.assertRaises(actions.NotFound):
            actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "nosuchgame")
        with self.assertRaises(actions.NotFound):
            actions.plan_removal(self.roms, self.cfgs, "nosuchsystem", "galaga")

    def test_bad_names_are_rejected(self):
        for system, name in (("mame-libretro", "../galaga"), ("mame-libretro", "a/b"), ("..", "galaga"),
                             ("mame-libretro", ""), ("mame-libretro", ".hidden"), ("", "galaga"), ("a b", "galaga")):
            with self.assertRaises(actions.BadRequest, msg="%s/%s" % (system, name)):
                actions.plan_removal(self.roms, self.cfgs, system, name)

    def test_a_symlinked_rom_is_unlinked_not_followed(self):
        target = os.path.join(self.root, "outside.zip")
        with open(target, "wb") as f:
            f.write(b"keep me")
        os.symlink(target, os.path.join(self.roms, "mame-libretro", "linked.zip"))
        # symlinks are not games (inventory skips them), so planning treats them as unknown
        with self.assertRaises(actions.NotFound):
            actions.plan_removal(self.roms, self.cfgs, "mame-libretro", "linked")
        self.assertTrue(os.path.exists(target))


class ApplySafetyTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)

    def test_plan_paths_outside_the_system_folder_are_rejected(self):
        for rel in ("daphne/lair.daphne", "mame-libretro/../daphne/x", "../etc/passwd"):
            with self.assertRaises(actions.BadRequest, msg=rel):
                actions.apply_removal(self.roms, self.cfgs, "mame-libretro", "galaga", {"remove": [rel], "pin": False})

    def test_a_symlinked_directory_cannot_be_used_to_escape(self):
        outside = os.path.join(self.root, "outside")
        os.makedirs(outside)
        keep = os.path.join(outside, "keep.zip")
        write_bytes(keep, b"keep")
        os.symlink(outside, os.path.join(self.roms, "mame-libretro", "sneaky"))
        with self.assertRaises(actions.BadRequest):
            actions.apply_removal(self.roms, self.cfgs, "mame-libretro", "galaga",
                                  {"remove": ["mame-libretro/sneaky/keep.zip"], "pin": False})
        self.assertTrue(os.path.exists(keep))

    def test_already_missing_paths_are_skipped(self):
        removed = actions.apply_removal(self.roms, self.cfgs, "mame-libretro", "galaga",
                                        {"remove": ["mame-libretro/galaga.zip", "mame-libretro/nothere.png"], "pin": False})
        self.assertEqual(removed, ["mame-libretro/galaga.zip"])

    def test_a_planned_symlink_is_unlinked_and_its_target_kept(self):
        target = os.path.join(self.root, "target.png")
        write_bytes(target, b"t")
        link = os.path.join(self.roms, "mame-libretro", "snap", "galaga.png")
        os.remove(link)
        os.symlink(target, link)
        removed = actions.apply_removal(self.roms, self.cfgs, "mame-libretro", "galaga",
                                        {"remove": ["mame-libretro/snap/galaga.png"], "pin": False})
        self.assertEqual(removed, ["mame-libretro/snap/galaga.png"])
        self.assertTrue(os.path.exists(target))
        self.assertFalse(os.path.lexists(link))

    def test_pin_removal_tolerates_a_missing_config_or_missing_key(self):
        actions.apply_removal(self.roms, "/nonexistent", "mame-libretro", "galaga", {"remove": [], "pin": True})
        before = read_text(os.path.join(self.cfgs, "all", "emulators.cfg"))
        actions.apply_removal(self.roms, self.cfgs, "mame-libretro", "galaga", {"remove": [], "pin": True})
        self.assertEqual(read_text(os.path.join(self.cfgs, "all", "emulators.cfg")), before)


if __name__ == "__main__":
    unittest.main()
