"""Actions that change a cabinet: removing a game (always planned first, never outside the ROM folder)."""
from __future__ import annotations

import os
import re
import shutil
from typing import List

from . import inventory

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]*$")
ART_DIRS = ("snap", "wheel", "marquee", "flyer", "title", "hqsnap", "fanart")


class BadRequest(Exception):
    pass


class NotFound(Exception):
    pass


def _check(system: str, name: str) -> None:
    if not NAME_RE.match(system or "") or not NAME_RE.match(name or "") or ".." in system or ".." in name:
        raise BadRequest("invalid system or game name")


def _find_game_file(roms: str, system: str, name: str) -> str:
    sdir = os.path.join(roms, system)
    if not os.path.isdir(sdir) or os.path.islink(sdir):
        raise NotFound("unknown system")
    for e in _entries(sdir):
        if e.is_symlink():
            continue
        kind = "d" if e.is_dir(follow_symlinks=False) else "f" if e.is_file(follow_symlinks=False) else None
        if kind and inventory.game_for(system, kind, e.name) == (name, e.name):
            return e.name
    raise NotFound("game not installed")


def _entries(path: str):
    """Directory entries with the iterator closed (os.scandir leaks a file handle otherwise)."""
    with os.scandir(path) as it:
        return list(it)


def _stem(filename: str) -> str:
    return filename.rpartition(".")[0] if "." in filename else filename


def plan_removal(roms: str, cfgs: str, system: str, name: str,
                 with_art: bool = False, with_saves: bool = False, with_scores: bool = False) -> dict:
    """What would be removed (paths relative to the ROM folder). Deletes nothing."""
    _check(system, name)
    file = _find_game_file(roms, system, name)
    sdir = os.path.join(roms, system)
    remove: List[str] = ["%s/%s" % (system, file)]

    def add_if_exists(rel: str) -> None:
        if os.path.lexists(os.path.join(roms, rel)):
            remove.append(rel)

    core_dirs = sorted(e.name for e in _entries(sdir)
                       if e.is_dir(follow_symlinks=False) and e.name not in ART_DIRS)
    if with_art:
        for art in ART_DIRS:
            adir = os.path.join(sdir, art)
            if os.path.isdir(adir):
                for e in sorted(_entries(adir), key=lambda e: e.name):
                    if (e.is_file(follow_symlinks=False) or e.is_symlink()) and _stem(e.name) == name:
                        remove.append("%s/%s/%s" % (system, art, e.name))
    if with_saves:
        for e in sorted(_entries(sdir), key=lambda e: e.name):
            if e.is_file(follow_symlinks=False) and (
                    e.name == file + ".cfg" or e.name.startswith(name + ".state") or e.name.startswith(file + ".state")):
                remove.append("%s/%s" % (system, e.name))
        for core in core_dirs:
            for sub, fname in (("cfg", name + ".cfg"), ("diff", name + ".dif"), ("inp", name + ".inp")):
                add_if_exists("%s/%s/%s/%s" % (system, core, sub, fname))
    if with_scores:
        for core in core_dirs:
            add_if_exists("%s/%s/hi/%s.hi" % (system, core, name))
            add_if_exists("%s/%s/nvram/%s.nv" % (system, core, name))
            add_if_exists("%s/%s/nvram/%s" % (system, core, name))
    pins = inventory.parse_emulators_cfg(inventory._read(os.path.join(cfgs, "all", "emulators.cfg")))
    return {"system": system, "name": name, "remove": sorted(set(remove)), "pin": ("%s_%s" % (system, name)) in pins}


def _inside(root: str, path: str) -> bool:
    root = os.path.realpath(root)
    parent = os.path.realpath(os.path.dirname(path))
    return parent == root or parent.startswith(root + os.sep)


def apply_removal(roms: str, cfgs: str, system: str, name: str, plan: dict) -> List[str]:
    """Delete exactly the planned paths (never outside the ROM folder) and drop the game's per-game core pin."""
    _check(system, name)
    removed: List[str] = []
    for rel in plan["remove"]:
        if not rel.startswith(system + "/") or ".." in rel.split("/"):
            raise BadRequest("plan path outside the system folder: %s" % rel)
        full = os.path.join(roms, rel)
        if not _inside(roms, full):
            raise BadRequest("plan path escapes the ROM folder: %s" % rel)
        if os.path.islink(full):
            os.unlink(full)  # never follow a link out of the folder
        elif os.path.isdir(full):
            shutil.rmtree(full)
        elif os.path.exists(full):
            os.remove(full)
        else:
            continue
        removed.append(rel)
    if plan.get("pin"):
        _remove_pin(cfgs, "%s_%s" % (system, name))
    return sorted(removed)


def _remove_pin(cfgs: str, key: str) -> None:
    path = os.path.join(cfgs, "all", "emulators.cfg")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return
    kept = [ln for ln in lines if ln.partition("=")[0].strip() != key]
    if len(kept) == len(lines):
        return
    tmp = path + ".rinkmasterd.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(kept) + ("\n" if kept else ""))
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
