"""Which emulators are really installed on this cabinet (not just configured).

A RetroPie `emulators.cfg` lists commands such as
  lr-mame2010 = "/opt/retropie/emulators/retroarch/bin/retroarch -L /opt/retropie/libretrocores/lr-mame2010/mame2010_libretro.so --config ... %ROM%"
An emulator counts as installed when its executable exists and, for libretro, the `-L` core file exists too.
"""
from __future__ import annotations

import os
import shlex
import shutil
from typing import List

from . import inventory


def required_paths(command: str) -> List[str]:
    """Executable (first token) plus the libretro core after `-L`, if any."""
    try:
        tokens = shlex.split(command)
    except ValueError:
        return []
    if not tokens:
        return []
    paths = [tokens[0]]
    if "-L" in tokens:
        i = tokens.index("-L")
        if i + 1 < len(tokens):
            paths.append(tokens[i + 1])
    return paths


def _present(path: str, executable: bool) -> bool:
    if "/" in path:
        return os.access(path, os.X_OK) if executable else os.path.exists(path)
    return shutil.which(path) is not None


def is_installed(command: str) -> bool:
    paths = required_paths(command)
    if not paths:
        return False
    return all(_present(p, executable=(i == 0)) for i, p in enumerate(paths))


def list_emulators(configs_path: str) -> dict:
    systems = []
    try:
        names = sorted(d for d in os.listdir(configs_path) if d != "all")
    except OSError:
        names = []
    for system in names:
        path = os.path.join(configs_path, system, "emulators.cfg")
        if not os.path.isfile(path):
            continue
        cfg = inventory.parse_emulators_cfg(inventory._read(path))
        emus = [{"id": eid, "installed": is_installed(cfg[eid]), "command": cfg[eid]}
                for eid in inventory.emulator_ids(cfg)]
        systems.append({"name": system, "defaultEmulator": cfg.get("default"), "emulators": emus,
                        "hasInstalledEmulator": any(e["installed"] for e in emus)})
    return {"systems": systems}
