"""Builds a cabinet's game inventory straight from the RetroPie folders (no SSH round trips).

Mirrors the Swift `InventoryParser` in the app: games per system, each with the emulator that will run
it (a per-game pin in all/emulators.cfg, else the system default).
"""
from __future__ import annotations

import os
from typing import Dict, List, Optional, Tuple

# Systems whose games are ROM zips.
ZIP_SYSTEMS = {"mame-libretro", "arcade", "mame-advmame", "mame-mame4all", "fba", "neogeo"}
# Extensions that are never games (config, saves, art, notes).
NON_GAME_EXTENSIONS = {"cfg", "txt", "png", "jpg", "jpeg", "db", "xml", "ini", "srm", "sav", "nv", "hi",
                       "bak", "log", "mng", "mp4", "avi"}


def parse_emulators_cfg(text: str) -> Dict[str, str]:
    """`key = "value"` lines (emulators.cfg and the per-game pins in all/emulators.cfg)."""
    entries: Dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        if key:
            entries[key] = value
    return entries


def emulator_ids(cfg: Dict[str, str]) -> List[str]:
    return sorted(k for k in cfg if k != "default")


def game_for(system: str, kind: str, entry: str) -> Optional[Tuple[str, str]]:
    """(name, file) if a directory entry is a game for this system, else None. `kind` is 'f' or 'd'."""
    if entry.startswith("."):
        return None
    base, dot, ext = entry.rpartition(".")
    if not dot:
        base, ext = entry, ""
    ext = ext.lower()
    if system == "daphne":
        return (base, entry) if kind == "d" and ext == "daphne" else None
    if kind != "f" or not base:
        return None
    if system in ZIP_SYSTEMS:
        return (base, entry) if ext == "zip" else None
    if ext in NON_GAME_EXTENSIONS or ext.startswith("state"):
        return None
    return (base, entry)


def _read(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def build_inventory(roms_path: str, configs_path: str) -> dict:
    pins = parse_emulators_cfg(_read(os.path.join(configs_path, "all", "emulators.cfg")))
    systems = []
    try:
        system_dirs = sorted(e.name for e in os.scandir(roms_path) if e.is_dir() and not e.name.startswith("."))
    except OSError:
        system_dirs = []
    for system in system_dirs:
        cfg = parse_emulators_cfg(_read(os.path.join(configs_path, system, "emulators.cfg")))
        default = cfg.get("default")
        games = []
        for e in os.scandir(os.path.join(roms_path, system)):
            if e.is_symlink():
                continue
            kind = "d" if e.is_dir(follow_symlinks=False) else "f" if e.is_file(follow_symlinks=False) else None
            if kind is None:
                continue
            found = game_for(system, kind, e.name)
            if not found:
                continue
            name, file = found
            pin = pins.get("%s_%s" % (system, name))
            st = e.stat(follow_symlinks=False)
            games.append({
                "system": system, "name": name, "file": file,
                "emulator": pin if pin is not None else default,
                "isPinned": pin is not None,
                "size": 0 if kind == "d" else st.st_size,
                "mtime": int(st.st_mtime),
            })
        if games:
            games.sort(key=lambda g: g["name"].lower())
            systems.append({"name": system, "defaultEmulator": default,
                            "emulators": emulator_ids(cfg), "games": games})
    return {"systems": systems, "totalGames": sum(len(s["games"]) for s in systems)}
