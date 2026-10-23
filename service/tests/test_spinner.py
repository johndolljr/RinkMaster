import os
import shutil
import tempfile
import unittest

from rinkmasterd import spinner


def run(smoother, counts_by_tick, dt=4.0, extra_ticks=200):
    """Feed one report per tick (0 = none); returns everything sent, tick by tick."""
    sent = []
    for c in counts_by_tick:
        if c:
            smoother.add(c)
        sent.append(smoother.step(dt))
    for _ in range(extra_ticks):
        sent.append(smoother.step(dt))
    return sent


class SmootherTests(unittest.TestCase):
    def test_total_movement_is_preserved_exactly(self):
        for tau in (10, 25, 60):
            sm = spinner.Smoother(tau)
            sent = run(sm, [40, 0, 0, 0, 37, 0, 5, 0, 0, 0, 0, 0, 40] + [0] * 40)
            self.assertEqual(sum(sent), 40 + 37 + 5 + 40)

    def test_negative_motion_is_preserved_too(self):
        sm = spinner.Smoother(25)
        sent = run(sm, [-40, 0, 0, 17, 0, -9])
        self.assertEqual(sum(sent), -40 + 17 - 9)
        self.assertTrue(all(isinstance(n, int) for n in sent))

    def test_a_lump_is_spread_over_many_ticks(self):
        sm = spinner.Smoother(25)
        sent = run(sm, [40], extra_ticks=60)
        nonzero = [n for n in sent if n]
        self.assertGreater(len(nonzero), 8)          # not one jump
        self.assertLessEqual(max(sent), 8)           # no tick carries more than a fifth of it
        self.assertEqual(sum(sent), 40)

    def test_bursty_input_gives_a_steadier_output_than_input_per_frame(self):
        # reports at irregular gaps (ms): 0 for a while, then lumps, as a sparse spinner sends them
        gaps = [8, 40, 12, 48, 10, 44, 9, 41, 12, 47, 10, 40]
        times, t = [], 0
        for g in gaps:
            t += g
            times.append(t)

        def per_frame(series_ms, frame=16.7):
            frames = {}
            for ms, v in series_ms:
                frames[int(ms / frame)] = frames.get(int(ms / frame), 0) + v
            n = int(max(ms for ms, _ in series_ms) / frame) + 1
            return [frames.get(i, 0) for i in range(n)]

        raw = [(ms, 40) for ms in times]
        sm = spinner.Smoother(25)
        out, now, queue = [], 0.0, list(times)
        while now < times[-1] + 100:
            while queue and queue[0] <= now:
                sm.add(40)
                queue.pop(0)
            out.append((now, sm.step(4.0)))
            now += 4.0
        window = [v for v in per_frame(raw)[2:-2]]
        window_out = [v for v in per_frame(out)[2:-2]]
        spread = lambda xs: max(xs) - min(xs)  # noqa: E731
        self.assertLess(spread(window_out), spread(window))

    def test_idle_flushes_the_remainder_so_nothing_is_stranded(self):
        sm = spinner.Smoother(25, idle_ms=100)
        sm.add(3)
        sent = [sm.step(4.0) for _ in range(100)]
        self.assertEqual(sum(sent), 3)
        self.assertTrue(sm.settled)

    def test_step_with_nothing_to_do_returns_zero(self):
        sm = spinner.Smoother()
        self.assertEqual(sm.step(4.0), 0)
        self.assertTrue(sm.settled)


class FindDeviceTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, True)

    def device(self, n, name, rel=None):
        d = os.path.join(self.root, "event%d" % n, "device")
        os.makedirs(os.path.join(d, "capabilities"))
        with open(os.path.join(d, "name"), "w") as f:
            f.write(name + "\n")
        if rel is not None:
            with open(os.path.join(d, "capabilities", "rel"), "w") as f:
                f.write(rel + "\n")

    def test_finds_the_mouse_like_device_by_name_part(self):
        self.device(0, "LINKFLY USB MOUSE  LINKFLY MOUSE ", "903")
        self.device(3, "XGaming X-Arcade 2", "903")
        self.device(10, "LINKFLY other", "903")
        self.assertEqual(spinner.find_device("linkfly", self.root), "/dev/input/event0")

    def test_skips_devices_without_relative_axes_and_unknown_names(self):
        self.device(1, "LINKFLY keyboard half", "0")
        self.device(2, "LINKFLY mouse half", "3")
        self.assertEqual(spinner.find_device("LINKFLY", self.root), "/dev/input/event2")
        self.assertIsNone(spinner.find_device("nothing", self.root))

    def test_tolerates_missing_capability_files(self):
        self.device(4, "LINKFLY broken")
        self.assertIsNone(spinner.find_device("LINKFLY", self.root))
        self.assertIsNone(spinner.find_device("LINKFLY", os.path.join(self.root, "missing")))
