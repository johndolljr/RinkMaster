import os
import shutil
import stat
import unittest

from rinkmasterd import frontend
from tests.fixtures import make_tree, write


def make_attract(root, cfgs, log):
    """Attract-Mode emulator configs plus a fake `attract` that records its arguments."""
    emu = os.path.join(cfgs, "all", "attractmode", "emulators")
    write(os.path.join(emu, "Multiple Arcade Machine Emulator.cfg"),
          b"executable /x/runcommand.sh\nrompath /home/pi/RetroPie/roms/mame-libretro\nsystem Multiple Arcade Machine Emulator\n")
    write(os.path.join(emu, "Arcade.cfg"), b"rompath /home/pi/RetroPie/roms/arcade\nsystem Arcade\n")
    write(os.path.join(emu, "Atari 2600.cfg"), b"rompath /home/pi/RetroPie/roms/atari2600\n")
    fake = os.path.join(root, "fake-attract")
    with open(fake, "w") as f:
        f.write('#!/bin/sh\necho "$@" >> "%s"\n' % log)
    os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
    return fake


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.log = os.path.join(self.root, "attract.log")

    def test_attract_romlist_is_rebuilt_for_the_matching_emulator_only(self):
        fake = make_attract(self.root, self.cfgs, self.log)
        result = frontend.refresh_lists(self.cfgs, "mame-libretro", attract_bin=fake)
        self.assertEqual(result["frontend"], "attract-mode")
        self.assertEqual(result["refreshed"], ["Multiple Arcade Machine Emulator"])
        self.assertEqual(result["errors"], [])
        with open(self.log) as f:
            self.assertEqual(f.read().strip(),
                             "--build-romlist Multiple Arcade Machine Emulator -o Multiple Arcade Machine Emulator")

    def test_other_systems_match_their_own_configs(self):
        fake = make_attract(self.root, self.cfgs, self.log)
        self.assertEqual(frontend.refresh_lists(self.cfgs, "atari2600", attract_bin=fake)["refreshed"], ["Atari 2600"])
        self.assertEqual(frontend.refresh_lists(self.cfgs, "daphne", attract_bin=fake)["refreshed"], [])

    def test_no_attract_configs_means_emulationstation_and_nothing_to_do(self):
        result = frontend.refresh_lists(self.cfgs, "mame-libretro", attract_bin="/nonexistent")
        self.assertEqual(result, {"frontend": "emulationstation", "refreshed": [], "errors": []})

    def test_missing_attract_binary_is_reported_not_raised(self):
        make_attract(self.root, self.cfgs, self.log)
        result = frontend.refresh_lists(self.cfgs, "mame-libretro", attract_bin="/nonexistent/attract")
        self.assertEqual(result["refreshed"], [])
        self.assertEqual(len(result["errors"]), 1)
        self.assertIn("Multiple Arcade Machine Emulator", result["errors"][0])

    def test_failing_attract_is_reported(self):
        make_attract(self.root, self.cfgs, self.log)
        bad = os.path.join(self.root, "bad-attract")
        with open(bad, "w") as f:
            f.write("#!/bin/sh\nexit 3\n")
        os.chmod(bad, 0o755)
        result = frontend.refresh_lists(self.cfgs, "mame-libretro", attract_bin=bad)
        self.assertEqual(result["refreshed"], [])
        self.assertIn("exit 3", result["errors"][0])


    def test_non_cfg_files_and_unreadable_configs_are_ignored(self):
        fake = make_attract(self.root, self.cfgs, self.log)
        emu = os.path.join(self.cfgs, "all", "attractmode", "emulators")
        write(os.path.join(emu, "notes.txt"), b"rompath /home/pi/RetroPie/roms/mame-libretro\n")
        os.makedirs(os.path.join(emu, "Broken.cfg"))  # a directory: opening it fails
        result = frontend.refresh_lists(self.cfgs, "mame-libretro", attract_bin=fake)
        self.assertEqual(result["refreshed"], ["Multiple Arcade Machine Emulator"])


if __name__ == "__main__":
    unittest.main()


def fake_proc(root, procs):
    """A fake /proc: {pid: [argv...]}."""
    proc = os.path.join(root, "proc")
    for pid, args in procs.items():
        write(os.path.join(proc, str(pid), "cmdline"), b"\0".join(a.encode() for a in args) + b"\0")
    return proc


class RestartTests(unittest.TestCase):
    ES = ["/opt/retropie/supplementary/emulationstation/emulationstation"]

    def setUp(self):
        self.root, self.roms, self.cfgs = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.flag = os.path.join(self.root, "es-restart")
        self.killed = []

    def restart(self, procs, **kw):
        proc = fake_proc(self.root, procs)
        return frontend.restart(self.cfgs, proc_root=proc, restart_flag=self.flag,
                                kill=lambda pid, sig: self.killed.append(pid), **kw)

    def test_emulationstation_is_signalled_and_flagged_for_relaunch(self):
        result = self.restart({10: ["/bin/bash", "/usr/bin/emulationstation"], 11: ["/bin/sh", "/x/emulationstation.sh"], 12: self.ES})
        self.assertEqual(self.killed, [12])  # the binary only, not the launcher scripts
        self.assertTrue(os.path.exists(self.flag))
        self.assertEqual((result["frontend"], result["restarted"], result["errors"]), ("emulationstation", True, []))

    def test_refuses_while_a_game_is_running_unless_forced(self):
        procs = {12: self.ES, 20: ["/bin/bash", "/opt/retropie/supplementary/runcommand/runcommand.sh", "0", "_SYS_", "x"]}
        with self.assertRaises(frontend.Busy):
            self.restart(procs)
        self.assertEqual(self.killed, [])
        self.assertFalse(os.path.exists(self.flag))
        self.assertTrue(self.restart(procs, force=True)["restarted"])
        self.assertEqual(self.killed, [12])

    def test_not_running_does_nothing(self):
        result = self.restart({1: ["/sbin/init"]})
        self.assertFalse(result["restarted"])
        self.assertEqual(self.killed, [])
        self.assertFalse(os.path.exists(self.flag))

    def test_kill_failures_are_reported(self):
        def boom(pid, sig):
            raise PermissionError("nope")
        proc = fake_proc(self.root, {12: self.ES})
        result = frontend.restart(self.cfgs, proc_root=proc, restart_flag=self.flag, kill=boom)
        self.assertFalse(result["restarted"])
        self.assertEqual(len(result["errors"]), 1)

    def test_missing_proc_is_just_not_running(self):
        result = frontend.restart(self.cfgs, proc_root=os.path.join(self.root, "nope"), restart_flag=self.flag)
        self.assertFalse(result["restarted"])

    def test_attract_rebuilds_every_romlist_and_does_not_restart(self):
        log = os.path.join(self.root, "attract.log")
        fake = make_attract(self.root, self.cfgs, log)
        result = frontend.restart(self.cfgs, attract_bin=fake, proc_root=os.path.join(self.root, "nope"))
        self.assertEqual(result["frontend"], "attract-mode")
        self.assertFalse(result["restarted"])
        self.assertEqual(sorted(result["refreshed"]), ["Arcade", "Atari 2600", "Multiple Arcade Machine Emulator"])
        with open(log) as f:
            self.assertEqual(len(f.read().strip().splitlines()), 3)

    def test_attract_build_failures_are_reported(self):
        make_attract(self.root, self.cfgs, os.path.join(self.root, "a.log"))
        result = frontend.restart(self.cfgs, attract_bin="/nonexistent")
        self.assertEqual(result["refreshed"], [])
        self.assertEqual(len(result["errors"]), 3)
