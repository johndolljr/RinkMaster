"""Keep the cabinet's frontend game list in step with the ROM folder.

Attract-Mode only lists a game after its romlist is rebuilt (`attract --build-romlist NAME -o NAME`), so after
adding or removing a game the matching emulator's romlist is rebuilt. EmulationStation only rescans its folders when it
starts, so `restart` (an explicit action, never part of an add or remove) restarts it, and rebuilds every Attract-Mode list.
"""
from __future__ import annotations

import os
import signal
import subprocess
from typing import List, Tuple

ATTRACT_BIN = "/usr/bin/attract"
ES_RESTART_FLAG = "/tmp/es-restart"  # emulationstation.sh relaunches ES when this exists after ES exits


class Busy(Exception):
    """A game is running, so restarting the frontend would end it."""


def _attract_emulators(configs_path: str) -> Tuple[bool, List[Tuple[str, str]]]:
    """(is attract-mode, [(emulator name, rompath)])"""
    emu_dir = os.path.join(configs_path, "all", "attractmode", "emulators")
    if not os.path.isdir(emu_dir):
        return False, []
    out = []
    for fname in sorted(os.listdir(emu_dir)):
        if not fname.endswith(".cfg"):
            continue
        rompath = ""
        try:
            with open(os.path.join(emu_dir, fname), "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("rompath"):
                        rompath = line[len("rompath"):].strip()
                        break
        except OSError:
            continue
        out.append((fname[:-4], rompath))
    return True, out


def refresh_lists(configs_path: str, system: str, attract_bin: str = ATTRACT_BIN, timeout: int = 120) -> dict:
    is_attract, emulators = _attract_emulators(configs_path)
    if not is_attract:
        return {"frontend": "emulationstation", "refreshed": [], "errors": []}
    refreshed: List[str] = []
    errors: List[str] = []
    for name, rompath in emulators:
        if os.path.basename(rompath.rstrip("/")) != system:
            continue
        try:
            r = subprocess.run([attract_bin, "--build-romlist", name, "-o", name], capture_output=True,
                               text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as e:
            errors.append("%s: %s" % (name, e))
            continue
        if r.returncode != 0:
            errors.append("%s: exit %d %s" % (name, r.returncode, (r.stderr or "").strip()[-200:]))
        else:
            refreshed.append(name)
    return {"frontend": "attract-mode", "refreshed": refreshed, "errors": errors}


def _cmdlines(proc_root: str) -> List[Tuple[int, List[str]]]:
    out = []
    try:
        entries = os.listdir(proc_root)
    except OSError:
        return out
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            with open(os.path.join(proc_root, entry, "cmdline"), "rb") as f:
                args = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
        except OSError:
            continue
        if args:
            out.append((int(entry), args))
    return out


def restart(configs_path: str, force: bool = False, attract_bin: str = ATTRACT_BIN, proc_root: str = "/proc",
            restart_flag: str = ES_RESTART_FLAG, kill=os.kill) -> dict:
    """Make new games show up. EmulationStation: restart it (its wrapper script starts it again when the restart flag
    exists). Attract-Mode: rebuild every romlist; it reads them when it next starts. Raises Busy while a game is running
    unless `force`."""
    is_attract, emulators = _attract_emulators(configs_path)
    if is_attract:
        refreshed: List[str] = []
        errors: List[str] = []
        for name, _ in emulators:
            try:
                r = subprocess.run([attract_bin, "--build-romlist", name, "-o", name], capture_output=True, text=True, timeout=120)
            except (OSError, subprocess.TimeoutExpired) as e:
                errors.append("%s: %s" % (name, e))
                continue
            if r.returncode != 0:
                errors.append("%s: exit %d %s" % (name, r.returncode, (r.stderr or "").strip()[-200:]))
            else:
                refreshed.append(name)
        return {"frontend": "attract-mode", "restarted": False, "refreshed": refreshed, "errors": errors,
                "message": "Game lists rebuilt; Attract-Mode shows them the next time it starts."}
    procs = _cmdlines(proc_root)
    if not force and any(os.path.basename(a) == "runcommand.sh" for _, args in procs for a in args[:3]):
        raise Busy("a game is running; restarting EmulationStation would end it")
    me = os.getuid()
    targets = [pid for pid, args in procs
               if os.path.basename(args[0]) == "emulationstation" and _owned_by(proc_root, pid, me)]
    if not targets:
        return {"frontend": "emulationstation", "restarted": False, "refreshed": [], "errors": [],
                "message": "EmulationStation is not running."}
    with open(restart_flag, "w"):
        pass
    errors = []
    for pid in targets:
        try:
            kill(pid, signal.SIGTERM)
        except OSError as e:
            errors.append("%d: %s" % (pid, e))
    return {"frontend": "emulationstation", "restarted": not errors, "refreshed": [], "errors": errors,
            "message": "EmulationStation is restarting and will list the new games."}


def _owned_by(proc_root: str, pid: int, uid: int) -> bool:
    try:
        return os.stat(os.path.join(proc_root, str(pid))).st_uid == uid
    except OSError:
        return False
