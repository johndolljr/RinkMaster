import os
import shutil
import tempfile
import unittest

from rinkmasterd import quitcombo

SEL, STA = 0x13A, 0x13B


class ComboTests(unittest.TestCase):
    def test_both_held_long_enough_fires_once(self):
        t = quitcombo.ComboTracker(SEL, STA, hold=1.5)
        t.event("d1", SEL, 1, 0.0)
        self.assertFalse(t.due(0.5))
        t.event("d1", STA, 1, 0.2)
        self.assertFalse(t.due(1.0))
        self.assertTrue(t.due(1.8))
        self.assertFalse(t.due(2.5))  # not again while still held

    def test_releasing_one_button_cancels_and_re_arms(self):
        t = quitcombo.ComboTracker(SEL, STA, hold=1.0)
        t.event("d1", SEL, 1, 0.0); t.event("d1", STA, 1, 0.1)
        t.event("d1", STA, 0, 0.5)
        self.assertFalse(t.due(5.0))
        t.event("d1", STA, 1, 6.0)
        self.assertFalse(t.due(6.5))
        self.assertTrue(t.due(7.1))

    def test_one_button_alone_and_other_buttons_never_fire(self):
        t = quitcombo.ComboTracker(SEL, STA, hold=0.5)
        t.event("d1", SEL, 1, 0.0); t.event("d1", 0x130, 1, 0.0)
        self.assertFalse(t.due(10.0))

    def test_select_on_one_pad_and_start_on_another_still_combine(self):
        t = quitcombo.ComboTracker(SEL, STA, hold=0.5)
        t.event("d1", SEL, 1, 0.0); t.event("d2", STA, 1, 0.0)
        self.assertTrue(t.due(1.0))

    def test_either_pad_can_fire(self):
        t = quitcombo.ComboTracker(SEL, STA, hold=0.5)
        t.event("d2", SEL, 1, 0.0); t.event("d2", STA, 1, 0.0)
        self.assertTrue(t.due(1.0))


class HelperTests(unittest.TestCase):
    def test_find_devices_matches_names(self):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        for n, name in ((1, "Xarcade-to-Gamepad Device 1"), (2, "Other"), (10, "Xarcade-to-Gamepad Device 2")):
            d = os.path.join(root, "event%d" % n, "device")
            os.makedirs(d)
            with open(os.path.join(d, "name"), "w") as f:
                f.write(name)
        os.makedirs(os.path.join(root, "event3"))  # no name file
        self.assertEqual(quitcombo.find_devices("xarcade", root), ["/dev/input/event1", "/dev/input/event10"])

    def test_quit_standalone_reports_what_matched(self):
        class R:
            def __init__(self, rc): self.returncode = rc
        calls = []
        def runner(cmd):
            calls.append(cmd)
            return R(0 if "stella" in cmd[-1] else 1)
        self.assertEqual(quitcombo.quit_standalone(runner), ["emulators/stella/bin/stella"])
        self.assertEqual(len(calls), len(quitcombo.STANDALONE))
        self.assertTrue(all(c[:3] == ["pkill", "-TERM", "-f"] for c in calls))


class ConsoleKeyTests(unittest.TestCase):
    def test_start_and_select_become_reset_and_select_only_for_a_fresh_press_while_stella_runs(self):
        self.assertEqual(quitcombo.console_key(0x13B, 1, True), quitcombo.KEY_F2)   # START -> F2 (Reset)
        self.assertEqual(quitcombo.console_key(0x13A, 1, True), quitcombo.KEY_F1)   # SELECT -> F1 (Select)
        self.assertIsNone(quitcombo.console_key(0x13B, 0, True))                    # release
        self.assertIsNone(quitcombo.console_key(0x13B, 1, False))                   # Stella not running
        self.assertIsNone(quitcombo.console_key(0x130, 1, True))                    # some other button

    def test_stella_running_follows_pgrep(self):
        class R:
            def __init__(self, rc): self.returncode = rc
        self.assertTrue(quitcombo.stella_running(lambda *a, **k: R(0)))
        self.assertFalse(quitcombo.stella_running(lambda *a, **k: R(1)))
