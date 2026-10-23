import shutil
import unittest

from rinkmasterd import emulators
from tests.fixtures import make_emulators, make_tree


class CommandParsingTests(unittest.TestCase):
    def test_retroarch_command_needs_binary_and_core(self):
        paths = emulators.required_paths('/opt/retropie/emulators/retroarch/bin/retroarch -L /opt/cores/x_libretro.so --config /c %ROM%')
        self.assertEqual(paths, ["/opt/retropie/emulators/retroarch/bin/retroarch", "/opt/cores/x_libretro.so"])

    def test_standalone_command_needs_only_the_binary(self):
        self.assertEqual(emulators.required_paths("/opt/x/stella -maxres 320x240 %ROM%"), ["/opt/x/stella"])

    def test_empty_or_unparseable_commands_require_nothing_installed(self):
        self.assertEqual(emulators.required_paths(""), [])
        self.assertEqual(emulators.required_paths('unterminated "quote'), [])


class InstalledCheckTests(unittest.TestCase):
    def test_empty_command_is_not_installed(self):
        self.assertFalse(emulators.is_installed(""))

    def test_bare_command_names_are_looked_up_on_path(self):
        self.assertTrue(emulators.is_installed("sh -c true"))
        self.assertFalse(emulators.is_installed("definitely-not-a-real-binary-xyz %ROM%"))


class EmulatorListTests(unittest.TestCase):
    def setUp(self):
        self.root, _, _ = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.cfgs = make_emulators(self.root)
        self.data = emulators.list_emulators(self.cfgs)

    def system(self, name):
        return next(s for s in self.data["systems"] if s["name"] == name)

    def test_installed_flag_per_emulator(self):
        mame = self.system("mame-libretro")
        flags = {e["id"]: e["installed"] for e in mame["emulators"]}
        self.assertEqual(flags, {"lr-mame2003": False, "lr-mame2010": True})
        self.assertEqual(mame["defaultEmulator"], "lr-mame2010")
        self.assertTrue(mame["hasInstalledEmulator"])

    def test_system_with_nothing_installed_is_flagged(self):
        atari = self.system("atari2600")
        self.assertFalse(atari["hasInstalledEmulator"])
        self.assertEqual([e["id"] for e in atari["emulators"]], ["stella"])

    def test_standalone_emulator_detected(self):
        self.assertTrue(self.system("daphne")["hasInstalledEmulator"])

    def test_systems_sorted_and_all_dir_ignored(self):
        self.assertEqual([s["name"] for s in self.data["systems"]], ["atari2600", "daphne", "mame-libretro"])

    def test_dirs_without_an_emulators_cfg_are_skipped(self):
        import os
        os.makedirs(os.path.join(self.cfgs, "empty-system"))
        self.assertNotIn("empty-system", [s["name"] for s in emulators.list_emulators(self.cfgs)["systems"]])

    def test_missing_configs_dir_is_empty(self):
        self.assertEqual(emulators.list_emulators("/nonexistent")["systems"], [])


if __name__ == "__main__":
    unittest.main()
