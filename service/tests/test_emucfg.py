import os
import shutil
import unittest

from rinkmasterd import emucfg
from tests.fixtures import make_tree


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class EmucfgBase(unittest.TestCase):
    def setUp(self):
        self.root, _, self.cfgs = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.sys_cfg = os.path.join(self.cfgs, "mame-libretro", "emulators.cfg")
        self.all_cfg = os.path.join(self.cfgs, "all", "emulators.cfg")


class SetDefaultTests(EmucfgBase):
    def test_rewrites_default_line_in_place_with_backup(self):
        before = read(self.sys_cfg)
        r = emucfg.set_default(self.cfgs, "mame-libretro", "lr-mame2003")
        self.assertTrue(r["changed"])
        self.assertFalse(r["dryRun"])
        self.assertEqual(r["previous"], "lr-mame2010")
        self.assertEqual(r["emulator"], "lr-mame2003")
        self.assertEqual(r["backup"], self.sys_cfg + ".bak")
        self.assertEqual(read(self.sys_cfg + ".bak"), before)
        self.assertEqual(read(self.sys_cfg), before.replace('default = "lr-mame2010"', 'default = "lr-mame2003"'))
        self.assertFalse(os.path.exists(self.sys_cfg + ".rinkmasterd.tmp"))

    def test_adds_default_when_missing(self):
        with open(self.sys_cfg, "w") as f:
            f.write('# comment\nlr-mame2003 = "x"\nlr-mame2010 = "y"')
        r = emucfg.set_default(self.cfgs, "mame-libretro", "lr-mame2010")
        self.assertIsNone(r["previous"])
        self.assertEqual(read(self.sys_cfg), '# comment\nlr-mame2003 = "x"\nlr-mame2010 = "y"\ndefault = "lr-mame2010"\n')

    def test_dry_run_changes_nothing(self):
        before = read(self.sys_cfg)
        r = emucfg.set_default(self.cfgs, "mame-libretro", "lr-mame2003", dry_run=True)
        self.assertTrue(r["dryRun"])
        self.assertTrue(r["changed"])
        self.assertEqual(read(self.sys_cfg), before)
        self.assertFalse(os.path.exists(self.sys_cfg + ".bak"))

    def test_idempotent_when_already_default(self):
        r = emucfg.set_default(self.cfgs, "mame-libretro", "lr-mame2010")
        self.assertFalse(r["changed"])
        self.assertIsNone(r["backup"])
        self.assertFalse(os.path.exists(self.sys_cfg + ".bak"))

    def test_second_apply_is_a_no_op(self):
        emucfg.set_default(self.cfgs, "mame-libretro", "lr-mame2003")
        after = read(self.sys_cfg)
        self.assertFalse(emucfg.set_default(self.cfgs, "mame-libretro", "lr-mame2003")["changed"])
        self.assertEqual(read(self.sys_cfg), after)

    def test_emulator_must_be_listed_for_the_system(self):
        with self.assertRaises(emucfg.BadRequest):
            emucfg.set_default(self.cfgs, "mame-libretro", "stella")
        with self.assertRaises(emucfg.BadRequest):
            emucfg.set_default(self.cfgs, "atari2600", "lr-stella2014")  # only named by default=, not an id line

    def test_bad_inputs(self):
        for system in ("", None, "../etc", "a/b", 'x"y', "a\nb", ".hidden", "all"):
            with self.assertRaises(emucfg.BadRequest, msg=repr(system)):
                emucfg.set_default(self.cfgs, system, "lr-mame2010")
        for emu in ("", None, 'a"b', "a\nb", "a b", 5):
            with self.assertRaises(emucfg.BadRequest, msg=repr(emu)):
                emucfg.set_default(self.cfgs, "mame-libretro", emu)

    def test_unknown_system_is_not_found(self):
        with self.assertRaises(emucfg.NotFound):
            emucfg.set_default(self.cfgs, "nosuch", "x")

    def test_file_mode_preserved(self):
        os.chmod(self.sys_cfg, 0o664)
        emucfg.set_default(self.cfgs, "mame-libretro", "lr-mame2003")
        self.assertEqual(os.stat(self.sys_cfg).st_mode & 0o777, 0o664)


class PinTests(EmucfgBase):
    def test_set_new_pin_appends_and_backs_up(self):
        before = read(self.all_cfg)
        r = emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", "lr-mame2003")
        self.assertTrue(r["changed"])
        self.assertEqual(r["key"], "mame-libretro_galaga")
        self.assertIsNone(r["previous"])
        self.assertEqual(read(self.all_cfg + ".bak"), before)
        self.assertEqual(read(self.all_cfg), before + 'mame-libretro_galaga = "lr-mame2003"\n')

    def test_change_existing_pin_keeps_order_and_other_lines(self):
        with open(self.all_cfg, "w") as f:
            f.write('# top\nmame-libretro_tempest = "lr-mame2003"\n\natari2600_Adventure = "stella"\n')
        r = emucfg.set_pin(self.cfgs, "mame-libretro", "tempest", "lr-mame2010")
        self.assertEqual(r["previous"], "lr-mame2003")
        self.assertEqual(read(self.all_cfg),
                         '# top\nmame-libretro_tempest = "lr-mame2010"\n\natari2600_Adventure = "stella"\n')

    def test_set_is_idempotent(self):
        r = emucfg.set_pin(self.cfgs, "mame-libretro", "tempest", "lr-mame2003")
        self.assertFalse(r["changed"])
        self.assertFalse(os.path.exists(self.all_cfg + ".bak"))

    def test_clear_removes_only_that_line(self):
        r = emucfg.set_pin(self.cfgs, "mame-libretro", "tempest", None)
        self.assertTrue(r["changed"])
        self.assertIsNone(r["emulator"])
        self.assertEqual(r["previous"], "lr-mame2003")
        self.assertEqual(read(self.all_cfg), 'atari2600_Adventure = "stella"\n')
        self.assertTrue(os.path.exists(self.all_cfg + ".bak"))

    def test_clear_missing_pin_is_a_no_op(self):
        r = emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", None)
        self.assertFalse(r["changed"])
        self.assertFalse(os.path.exists(self.all_cfg + ".bak"))

    def test_clear_when_all_cfg_missing(self):
        os.remove(self.all_cfg)
        self.assertFalse(emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", None)["changed"])

    def test_set_creates_all_cfg_when_missing(self):
        os.remove(self.all_cfg)
        r = emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", "lr-mame2003")
        self.assertIsNone(r["backup"])
        self.assertEqual(read(self.all_cfg), 'mame-libretro_galaga = "lr-mame2003"\n')

    def test_set_creates_all_dir_when_missing(self):
        shutil.rmtree(os.path.join(self.cfgs, "all"))
        emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", "lr-mame2003")
        self.assertTrue(os.path.isfile(self.all_cfg))

    def test_duplicate_lines_collapse_on_change(self):
        with open(self.all_cfg, "w") as f:
            f.write('mame-libretro_tempest = "a"\nx_y = "z"\nmame-libretro_tempest = "b"\n')
        emucfg.set_pin(self.cfgs, "mame-libretro", "tempest", "lr-mame2010")
        self.assertEqual(read(self.all_cfg), 'mame-libretro_tempest = "lr-mame2010"\nx_y = "z"\n')

    def test_set_without_trailing_newline(self):
        with open(self.all_cfg, "w") as f:
            f.write('a_b = "c"')
        emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", "lr-mame2003")
        self.assertEqual(read(self.all_cfg), 'a_b = "c"\nmame-libretro_galaga = "lr-mame2003"\n')

    def test_dry_run_touches_nothing(self):
        before = read(self.all_cfg)
        for emu in ("lr-mame2010", None):
            r = emucfg.set_pin(self.cfgs, "mame-libretro", "tempest", emu, dry_run=True)
            self.assertTrue(r["dryRun"])
            self.assertTrue(r["changed"])
        self.assertEqual(read(self.all_cfg), before)
        self.assertFalse(os.path.exists(self.all_cfg + ".bak"))

    def test_emulator_must_be_installed_for_the_system(self):
        with self.assertRaises(emucfg.BadRequest):
            emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", "daphne")

    def test_unknown_system(self):
        with self.assertRaises(emucfg.NotFound):
            emucfg.set_pin(self.cfgs, "nosuch", "galaga", "x")

    def test_bad_game_names(self):
        for game in ("", None, "../x", "a/b", 'a"b', "a\nb", "a=b", ".hidden", "a\\b", "x" * 200, 7):
            with self.assertRaises(emucfg.BadRequest, msg=repr(game)):
                emucfg.set_pin(self.cfgs, "mame-libretro", game, "lr-mame2003")
            with self.assertRaises(emucfg.BadRequest, msg=repr(game)):
                emucfg.set_pin(self.cfgs, "mame-libretro", game, None)

    def test_game_names_with_spaces_and_parens_are_fine(self):
        r = emucfg.set_pin(self.cfgs, "mame-libretro", "Pac-Man (Midway) v1.1", "lr-mame2003", dry_run=True)
        self.assertEqual(r["key"], "mame-libretro_Pac-Man (Midway) v1.1")

    def test_bad_system_and_emulator_types(self):
        with self.assertRaises(emucfg.BadRequest):
            emucfg.set_pin(self.cfgs, "../x", "galaga", None)
        with self.assertRaises(emucfg.BadRequest):
            emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", 5)
        with self.assertRaises(emucfg.BadRequest):
            emucfg.set_pin(self.cfgs, "mame-libretro", "galaga", 'a"b')


if __name__ == "__main__":
    unittest.main()
