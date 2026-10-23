"""Spinner smoother: turns a spinner's lumpy movement reports into an even stream.

Some spinners/trackballs report only when their sensor ticks, in uneven bursts (a 40 ms gap, then a lump). A game that looks at
the mouse once per frame (every 16.7 ms) sees no movement for two or three frames and then a jump, which feels jerky. This service
reads the real device (and grabs it so nothing else sees the lumpy version), spreads each report over a short window with an
exponential filter, and re-sends it as a new virtual mouse, "Smoothed Spinner". Total movement is unchanged; the only cost is
about one filter time constant of delay (14 ms by default).

  python3 -m rinkmasterd.spinner [--name LINKFLY] [--tau-ms 14] [--tick-ms 4] [--virtual-name "Smoothed Spinner"]

Runs as root (it needs /dev/uinput and the grab). Stop it and the real spinner is visible again.
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import math
import os
import select
import signal
import struct
import sys
import time
from typing import List, Optional, Tuple

EV_SYN, EV_KEY, EV_REL = 0, 1, 2
REL_X, REL_Y, REL_WHEEL = 0, 1, 8
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
SYN_REPORT = 0
EVENT_FMT = "llHHi"  # struct input_event on 64-bit Linux (what the Pis run)
EVENT_SIZE = struct.calcsize(EVENT_FMT)


class Smoother:
    """Exponential smoothing of relative motion on one axis, keeping the total exact.

    `add` takes the raw counts from a report. `step(dt_ms)` returns the whole counts to send now; fractions carry over. After
    `idle_ms` with no new input the remainder is flushed so the sum of everything sent equals the sum of everything received."""

    def __init__(self, tau_ms: float = 25.0, idle_ms: float = 150.0):
        self.tau = max(tau_ms, 0.001)
        self.idle_ms = idle_ms
        self.pool = 0.0     # received, not yet released
        self.carry = 0.0    # released, not yet a whole count
        self.quiet = 0.0    # ms since the last input

    def add(self, counts: int) -> None:
        self.pool += counts
        self.quiet = 0.0

    def step(self, dt_ms: float) -> int:
        self.quiet += dt_ms
        if self.quiet >= self.idle_ms:
            total = self.pool + self.carry
            self.pool = self.carry = 0.0
            return int(round(total))
        take = self.pool * (1.0 - math.exp(-dt_ms / self.tau))
        self.pool -= take
        self.carry += take
        whole = int(self.carry)  # truncates toward zero for both signs
        self.carry -= whole
        return whole

    @property
    def settled(self) -> bool:
        return self.pool == 0.0 and self.carry == 0.0


def find_device(name_part: str, root: str = "/sys/class/input") -> Optional[str]:
    """/dev/input/eventN of the first device whose name contains `name_part` (case-insensitive) and that moves like a mouse."""
    for path in sorted(glob.glob(os.path.join(root, "event*")), key=lambda p: int(p.rsplit("event", 1)[1])):
        try:
            with open(os.path.join(path, "device", "name")) as f:
                name = f.read().strip()
        except OSError:
            continue
        if name_part.lower() not in name.lower():
            continue
        try:  # sysfs shows the supported relative axes as hex bits: X is bit 0, Y is bit 1
            rel = int(open(os.path.join(path, "device", "capabilities", "rel")).read().split()[-1], 16)
        except (OSError, ValueError, IndexError):
            continue
        if rel & 0x1:
            return "/dev/input/" + os.path.basename(path)
    return None


# --- uinput plumbing (ioctl numbers for Linux on arm64/x86-64) ---
EVIOCGRAB = 0x40044590
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
UI_DEV_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405C5503, 0x5501, 0x5502


def create_virtual_mouse(name: str) -> int:  # pragma: no cover - needs /dev/uinput
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for ev in (EV_KEY, EV_REL, EV_SYN):
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    for btn in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE):
        fcntl.ioctl(fd, UI_SET_KEYBIT, btn)
    for rel in (REL_X, REL_Y, REL_WHEEL):
        fcntl.ioctl(fd, UI_SET_RELBIT, rel)
    setup = struct.pack("HHHH80sI", 0x03, 0x1209, 0x5350, 1, name.encode()[:79], 0)  # BUS_USB, a made-up vendor/product
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def emit(fd: int, etype: int, code: int, value: int) -> None:  # pragma: no cover
    os.write(fd, struct.pack(EVENT_FMT, 0, 0, etype, code, value))


def run(device: str, virtual_name: str, tau_ms: float, tick_ms: float, stop=lambda: False) -> None:  # pragma: no cover - needs hardware
    src = os.open(device, os.O_RDONLY | os.O_NONBLOCK)
    fcntl.ioctl(src, EVIOCGRAB, 1)
    out = create_virtual_mouse(virtual_name)
    axes = {REL_X: Smoother(tau_ms), REL_Y: Smoother(tau_ms)}
    last = time.monotonic()
    try:
        while not stop():
            ready, _, _ = select.select([src], [], [], tick_ms / 1000.0)
            if ready:
                try:
                    data = os.read(src, EVENT_SIZE * 64)
                except BlockingIOError:
                    data = b""
                if not data:
                    raise OSError("spinner went away")
                for off in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    _, _, etype, code, value = struct.unpack_from(EVENT_FMT, data, off)
                    if etype == EV_REL and code in axes:
                        axes[code].add(value)
                    elif etype == EV_REL or etype == EV_KEY:  # wheel and buttons pass straight through
                        emit(out, etype, code, value)
                        emit(out, EV_SYN, SYN_REPORT, 0)
            now = time.monotonic()
            dt = (now - last) * 1000.0
            last = now
            sent = False
            for code, smoother in axes.items():
                n = smoother.step(dt)
                if n:
                    emit(out, EV_REL, code, n)
                    sent = True
            if sent:
                emit(out, EV_SYN, SYN_REPORT, 0)
    finally:
        try:
            fcntl.ioctl(out, UI_DEV_DESTROY)
        except OSError:
            pass
        os.close(out)
        os.close(src)  # closing releases the grab


def main(argv: Optional[List[str]] = None) -> int:  # pragma: no cover - needs hardware
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--name", default="LINKFLY", help="part of the spinner's device name (default LINKFLY)")
    p.add_argument("--virtual-name", default="Smoothed Spinner")
    p.add_argument("--tau-ms", type=float, default=14.0, help="smoothing time constant; larger is smoother but laggier")
    p.add_argument("--tick-ms", type=float, default=4.0)
    args = p.parse_args(argv)
    stopping = {"flag": False}
    signal.signal(signal.SIGTERM, lambda *_: stopping.update(flag=True))
    deadline = time.time() + 60  # the spinner may enumerate a moment after boot
    device = find_device(args.name)
    while device is None and time.time() < deadline:
        time.sleep(1)
        device = find_device(args.name)
    if device is None:
        print("no device matching %r" % args.name, file=sys.stderr)
        return 1
    print("smoothing %s as %r (tau %.0f ms)" % (device, args.virtual_name, args.tau_ms), flush=True)
    run(device, args.virtual_name, args.tau_ms, args.tick_ms, stop=lambda: stopping["flag"])
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
