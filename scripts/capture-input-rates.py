#!/usr/bin/env python3
"""Measures how a spinner / trackball / mouse reports movement, to find out why it feels jerky.

Run on the cabinet as root (reads /dev/input/event*), or over SSH:
  ssh USER@HOST 'sudo python3 -' < scripts/capture-input-rates.py -- 120
  scripts/capture-input-rates.py [SECONDS]      (default 60; -h for this help)

Spin or roll each device while it runs. For every device that sends relative motion it prints: events per second, the typical
gap between reports, the longest pause while moving, and how big each report is. A smooth spinner reports every 1-8 ms with small
steady steps; a jerky one reports in bursts with long gaps or huge steps.
"""
import glob
import os
import select
import struct
import sys
import time

args = [a for a in sys.argv[1:] if a != "--"]
if args and args[0] in ("-h", "--help"):
    print(__doc__)
    sys.exit(0)
SECONDS = float(args[0]) if args else 60.0
FMT = "llHHi"  # struct input_event on 64-bit Linux
SIZE = struct.calcsize(FMT)
REL, REL_X, REL_Y, REL_WHEEL, REL_DIAL = 2, 0, 1, 8, 7

devices = {}
for path in sorted(glob.glob("/dev/input/event*")):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        print("cannot open %s: %s" % (path, e))
        continue
    name = open("/sys/class/input/%s/device/name" % os.path.basename(path)).read().strip()
    devices[fd] = {"path": path, "name": name, "t": [], "vals": [], "axes": {}}

def report(label):
    print("\n=== %s ===" % label, flush=True)
    for d in devices.values():
        if not d["t"]:
            continue
        t, v = d["t"], d["vals"]
        gaps = sorted(b - a for a, b in zip(t, t[1:]) if b - a < 1.0)  # gaps inside one movement, not between movements
        span = (t[-1] - t[0]) or 1e-9
        pct = lambda p: gaps[min(len(gaps) - 1, int(len(gaps) * p))] * 1000 if gaps else float("nan")
        big = sorted(v)
        print("\n%s  (%s)" % (d["name"], d["path"]))
        print("  reports: %d over %.1f s of movement  (%.0f/s while moving)" % (len(t), span, len(t) / span))
        print("  axes: %s" % ", ".join("%s=%d" % ({0: "X", 1: "Y", 8: "wheel", 7: "dial"}[a], n) for a, n in d["axes"].items()))
        print("  gap between reports: median %.1f ms, 90%% under %.1f ms, longest %.0f ms" % (pct(0.5), pct(0.9), (gaps[-1] * 1000) if gaps else 0))
        print("  step size: median %d, 90%% under %d, largest %d" % (big[len(big) // 2], big[int(len(big) * 0.9)], big[-1]))


end = time.time() + SECONDS
next_report = time.time() + 30
print("capturing %.0f s from %d devices; move the spinner/trackball now" % (SECONDS, len(devices)), flush=True)
while time.time() < end:
    if time.time() >= next_report:  # a running summary every 30 s, so a long capture can be read while it runs
        report("so far")
        next_report += 30
    ready, _, _ = select.select(list(devices), [], [], 0.5)
    for fd in ready:
        try:
            data = os.read(fd, SIZE * 64)
        except BlockingIOError:
            continue
        for off in range(0, len(data) - SIZE + 1, SIZE):
            sec, usec, etype, code, value = struct.unpack_from(FMT, data, off)
            if etype == REL and code in (REL_X, REL_Y, REL_WHEEL, REL_DIAL):
                d = devices[fd]
                d["t"].append(sec + usec / 1e6)
                d["vals"].append(abs(value))
                d["axes"][code] = d["axes"].get(code, 0) + 1

report("final")
