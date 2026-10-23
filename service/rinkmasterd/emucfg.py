"""Per-cabinet emulator management: the system default and per-game pins.

Edits RetroPie's `<configs>/<system>/emulators.cfg` (`default = "id"`) and the pin lines
`<system>_<game> = "id"` in `<configs>/all/emulators.cfg`. Every change keeps the other lines and their order,
writes a `.bak` copy of the previous file first and replaces the file atomically. Applying the same change twice
is a no-op (no write, no backup). `dry_run` returns the same result without touching anything.
"""
from __future__ import annotations

import os
import re
import shutil
from typing import List, Optional

from . import inventory

SYSTEM_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]*$")
EMULATOR_RE = SYSTEM_RE
# ROM names: letters, digits, spaces and the punctuation real ROM names use. No quotes, '=', slashes or control chars.
GAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+\-(),!&']*$")
MAX_GAME_LEN = 128


class BadRequest(Exception):
    pass


class NotFound(Exception):
    pass


def _system_cfg(configs: str, system) -> str:
    if (not isinstance(system, str) or not SYSTEM_RE.match(system) or ".." in system or system == "all"):
        raise BadRequest("invalid system name")
    path = os.path.join(configs, system, "emulators.cfg")
    if not os.path.isfile(path):
        raise NotFound("no emulators.cfg for system %s" % system)
    return path


def _check_game(game) -> None:
    if (not isinstance(game, str) or len(game) > MAX_GAME_LEN or not GAME_RE.match(game)
            or ".." in game or game.endswith(" ")):
        raise BadRequest("invalid game name")


def _check_emulator(path: str, system: str, emulator) -> None:
    if not isinstance(emulator, str) or not EMULATOR_RE.match(emulator):
        raise BadRequest("invalid emulator id")
    ids = inventory.emulator_ids(inventory.parse_emulators_cfg(inventory._read(path)))
    if emulator not in ids:
        raise BadRequest("emulator %s is not installed for %s (available: %s)" % (emulator, system, ", ".join(ids) or "none"))


def _lines(path: str) -> List[str]:
    return inventory._read(path).splitlines()


def _key_of(line: str) -> Optional[str]:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in stripped:
        return None
    return stripped.partition("=")[0].strip()


def _with_line(lines: List[str], key: str, value: Optional[str]) -> List[str]:
    """Replace the first `key` line in place (dropping repeats), append if absent; value None removes the key."""
    out, seen = [], False
    new = None if value is None else '%s = "%s"' % (key, value)
    for ln in lines:
        if _key_of(ln) != key:
            out.append(ln)
        elif not seen:
            seen = True
            if new is not None:
                out.append(new)
    if not seen and new is not None:
        out.append(new)
    return out


def _write(path: str, lines: List[str]) -> Optional[str]:
    """Back up the existing file to `<path>.bak`, then replace it atomically. Returns the backup path (or None)."""
    backup = None
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        backup = path + ".bak"
        shutil.copy2(path, backup)
    tmp = path + ".rinkmasterd.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    else:
        os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    return backup


def _apply(path: str, key: str, value: Optional[str], dry_run: bool) -> dict:
    old = _lines(path)
    new = _with_line(old, key, value)
    previous = inventory.parse_emulators_cfg("\n".join(old)).get(key)
    changed = new != old
    backup = None
    if changed and not dry_run:
        backup = _write(path, new)
    return {"file": path, "previous": previous, "changed": changed, "dryRun": dry_run, "backup": backup}


def set_default(configs: str, system, emulator, dry_run: bool = False) -> dict:
    path = _system_cfg(configs, system)
    _check_emulator(path, system, emulator)
    result = _apply(path, "default", emulator, dry_run)
    result.update({"system": system, "emulator": emulator})
    return result


def set_pin(configs: str, system, game, emulator: Optional[str], dry_run: bool = False) -> dict:
    """Pin `game` to `emulator`; emulator None clears the pin."""
    path = _system_cfg(configs, system)
    _check_game(game)
    if emulator is not None:
        _check_emulator(path, system, emulator)
    key = "%s_%s" % (system, game)
    result = _apply(os.path.join(configs, "all", "emulators.cfg"), key, emulator, dry_run)
    result.update({"system": system, "game": game, "key": key, "emulator": emulator})
    return result
