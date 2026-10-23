"""Arcade-panel helpers for standalone emulators (Stella, AdvanceMAME) on a cabinet with only arcade controls.

1. Hold SELECT + START to quit the emulator.
2. While Stella runs, START presses F2 (Atari Reset) and SELECT presses F1 (Atari Select), because Stella has no default gamepad
   mapping for the console switches, so a game could not be started from the panel.

RetroArch games already quit with SELECT + START. Standalone emulators (Stella, AdvanceMAME) have no gamepad quit, so on a cabinet
with only arcade controls there is no way out. This service watches the X-Arcade gamepads and, when SELECT and START are held
together for `--hold` seconds, ends the standalone emulator that is running. RetroArch is left alone (it has its own quit).

  python3 -m rinkmasterd.quitcombo [--hold 1.5] [--select 0x13a] [--start 0x13b] [--name Xarcade]

Runs as root. The button codes are the evdev codes of the gamepad's SELECT (BTN_SELECT 0x13a) and START (BTN_START 0x13b): js buttons 8 and 9 on the X-Arcade.
"""
from __future__ import annotations

import argparse
import glob
import os
import select
import struct
import subprocess
import sys
import time
from typing import Dict, List, Optional, Set

EV_KEY = 1
KEY_F1, KEY_F2 = 59, 60
CONSOLE_KEYS = {0x13B: KEY_F2, 0x13A: KEY_F1}  # START -> Reset, SELECT -> Select
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
STANDALONE = ["emulators/stella/bin/stella", "advmame", "emulators/advancemame"]  # process name fragments (pkill -f)


class ComboTracker:
    """SELECT and START down together (on the same pad or different ones) for `hold` seconds fires once, then both must be
    released before it can fire again. Pad identity is ignored: it is hard to know which pad a front button belongs to."""

    def __init__(self, select_code: int, start_code: int, hold: float = 1.5):
        self.codes = (select_code, start_code)
        self.hold = hold
        self.down: Dict[str, Set[int]] = {}
        self.since: Dict[str, Optional[float]] = {}
        self.fired: Dict[str, bool] = {}

    def event(self, device: str, code: int, value: int, now: float) -> None:
        if code not in self.codes:
            return
        device = "all"
        pressed = self.down.setdefault(device, set())
        if value:
            pressed.add(code)
        else:
            pressed.discard(code)
        if len(pressed) == 2:
            self.since.setdefault(device, now)
            if self.since[device] is None:
                self.since[device] = now
        else:
            self.since[device] = None
            self.fired[device] = False

    def due(self, now: float) -> bool:
        """True once when any device has held the combo long enough."""
        for device, started in self.since.items():
            if started is not None and not self.fired.get(device) and now - started >= self.hold:
                self.fired[device] = True
                return True
        return False


def find_devices(name_part: str, root: str = "/sys/class/input") -> List[str]:
    out = []
    for path in sorted(glob.glob(os.path.join(root, "event*")), key=lambda p: int(p.rsplit("event", 1)[1])):
        try:
            with open(os.path.join(path, "device", "name")) as f:
                if name_part.lower() in f.read().lower():
                    out.append("/dev/input/" + os.path.basename(path))
        except OSError:
            continue
    return out


def stella_running(runner=subprocess.run) -> bool:
    return runner(["pgrep", "-f", "emulators/stella/bin/stella"], stdout=subprocess.DEVNULL).returncode == 0


def console_key(code: int, value: int, stella: bool) -> Optional[int]:
    """The key to tap for a panel press: only on a fresh press, only while Stella is running."""
    return CONSOLE_KEYS.get(code) if (value == 1 and stella) else None


def quit_standalone(runner=subprocess.run) -> List[str]:
    """Asks each standalone emulator to end (SIGTERM); returns the patterns that matched a running process."""
    hit = []
    for pattern in STANDALONE:
        if runner(["pkill", "-TERM", "-f", pattern]).returncode == 0:
            hit.append(pattern)
    return hit


def create_virtual_keyboard(name: str) -> int:  # pragma: no cover - needs /dev/uinput
    from . import spinner as u
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    import fcntl
    for ev in (u.EV_KEY, u.EV_SYN):
        fcntl.ioctl(fd, u.UI_SET_EVBIT, ev)
    for key in CONSOLE_KEYS.values():
        fcntl.ioctl(fd, u.UI_SET_KEYBIT, key)
    fcntl.ioctl(fd, u.UI_DEV_SETUP, struct.pack("HHHH80sI", 0x03, 0x1209, 0x5351, 1, name.encode()[:79], 0))
    fcntl.ioctl(fd, u.UI_DEV_CREATE)
    return fd


def tap(fd: int, key: int) -> None:  # pragma: no cover
    for value in (1, 0):
        os.write(fd, struct.pack(EVENT_FMT, 0, 0, EV_KEY, key, value))
        os.write(fd, struct.pack(EVENT_FMT, 0, 0, 0, 0, 0))
        time.sleep(0.04)


def main(argv: Optional[List[str]] = None) -> int:  # pragma: no cover - needs the cabinet's devices
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--name", default="Xarcade-to-Gamepad")
    p.add_argument("--hold", type=float, default=1.5)
    p.add_argument("--select", type=lambda s: int(s, 0), default=0x13A)
    p.add_argument("--start", type=lambda s: int(s, 0), default=0x13B)
    args = p.parse_args(argv)
    deadline = time.time() + 60
    devices = find_devices(args.name)
    while not devices and time.time() < deadline:
        time.sleep(1)
        devices = find_devices(args.name)
    if not devices:
        print("no device matching %r" % args.name, file=sys.stderr)
        return 1
    fds = {os.open(d, os.O_RDONLY | os.O_NONBLOCK): d for d in devices}
    tracker = ComboTracker(args.select, args.start, args.hold)
    keyboard = create_virtual_keyboard("Panel Console Keys")
    print("watching %s; hold SELECT+START %.1f s to quit standalone emulators" % (", ".join(devices), args.hold), flush=True)
    while True:
        ready, _, _ = select.select(list(fds), [], [], 0.2)
        for fd in ready:
            try:
                data = os.read(fd, EVENT_SIZE * 32)
            except BlockingIOError:
                continue
            for off in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                _, _, etype, code, value = struct.unpack_from(EVENT_FMT, data, off)
                if etype == EV_KEY and value in (0, 1):
                    tracker.event(fds[fd], code, value, time.monotonic())
                    if code in CONSOLE_KEYS and value == 1:
                        key = console_key(code, value, stella_running())
                        if key:
                            tap(keyboard, key)
        if tracker.due(time.monotonic()):
            print("combo held: quit ->", quit_standalone() or "nothing running", flush=True)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
