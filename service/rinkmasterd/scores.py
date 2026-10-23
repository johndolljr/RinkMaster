"""High-score files on the cabinet: `.hi` (memory snapshots) and `.nv` (NVRAM), served raw and read-only.

Libretro and AdvMAME keep them under ``<system>/hi`` or ``<system>/<core>/hi`` (``nvram`` for ``.nv``). The core id used
by the API is ``<system>`` or ``<system>/<core>``; the Mac app decodes the bytes, the cabinet never interprets them.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import time
from typing import Dict, Iterator, List, Tuple

from .actions import NAME_RE, BadRequest, NotFound

KINDS = {"hi": ("hi", ".hi"), "nv": ("nvram", ".nv")}
CORE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]*(/[A-Za-z0-9][A-Za-z0-9._+\-]*)?$")

MAX_SCORE_BYTES = 65536  # real .hi files are a few hundred bytes

__all__ = ["BadRequest", "NotFound", "MAX_SCORE_BYTES", "list_scores", "read_score", "write_score"]


def _subdirs(path: str) -> List[str]:
    try:
        with os.scandir(path) as it:
            return sorted(e.name for e in it if e.is_dir(follow_symlinks=False) and not e.name.startswith("."))
    except OSError:
        return []


def _cores(roms: str) -> Iterator[Tuple[str, str]]:
    """(core id, folder) for every folder that can hold score files."""
    for system in _subdirs(roms):
        sdir = os.path.join(roms, system)
        yield system, sdir
        for sub in _subdirs(sdir):
            if sub not in ("hi", "nvram"):
                yield system + "/" + sub, os.path.join(sdir, sub)


_md5_cache: Dict[str, Tuple[int, int, str]] = {}  # path -> (size, mtime_ns, md5)


def _md5_of(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        h.update(f.read(MAX_SCORE_BYTES * 16))  # score files are tiny; NVRAM images a few KB
    return h.hexdigest()


def _md5(path: str, st: os.stat_result) -> str:
    """MD5 of the file, recomputed only when its size or modification time changed."""
    hit = _md5_cache.get(path)
    if hit and hit[0] == st.st_size and hit[1] == st.st_mtime_ns:
        return hit[2]
    digest = _md5_of(path)
    _md5_cache[path] = (st.st_size, st.st_mtime_ns, digest)
    return digest


def list_scores(roms: str) -> Dict[str, list]:
    files = []
    for core, folder in _cores(roms):
        for kind, (subdir, ext) in KINDS.items():
            d = os.path.join(folder, subdir)
            if os.path.islink(d):  # a link to a folder that is listed under its real name
                continue
            try:
                entries = list(os.scandir(d))
            except OSError:
                continue
            for e in entries:
                if e.name.startswith(".") or not e.name.endswith(ext) or not e.is_file(follow_symlinks=False):
                    continue
                st = e.stat(follow_symlinks=False)
                files.append({"core": core, "kind": kind, "game": e.name[: -len(ext)], "size": st.st_size, "mtime": int(st.st_mtime),
                              "md5": _md5(e.path, st)})
    files.sort(key=lambda f: (f["core"], f["kind"], f["game"]))
    return {"files": files}


def _score_path(roms: str, core: str, kind: str, game: str) -> str:
    if kind not in KINDS or not CORE_RE.match(core or "") or not NAME_RE.match(game or "") or ".." in core or ".." in game:
        raise BadRequest("invalid core, kind or game")
    subdir, ext = KINDS[kind]
    path = os.path.join(roms, *core.split("/"), subdir, game + ext)
    if any(os.path.islink(p) for p in (os.path.join(roms, core.split("/")[0]), os.path.dirname(path), path)) or not os.path.isfile(path):
        raise NotFound("no such score file")
    return path


def read_score(roms: str, core: str, kind: str, game: str) -> bytes:
    with open(_score_path(roms, core, kind, game), "rb") as f:
        return f.read()


def write_score(roms: str, core: str, kind: str, game: str, data: bytes, now: float = None) -> Dict[str, object]:
    """Replace an existing `.hi` file. The old file is kept beside it as `<name>.bak-<UTC time>`; the new one is
    written to a temp file and renamed into place so the emulator never sees a half-written file."""
    if kind != "hi":
        raise BadRequest("only .hi files can be written")
    if not data or len(data) > MAX_SCORE_BYTES:
        raise BadRequest("score file must be 1 to %d bytes" % MAX_SCORE_BYTES)
    path = _score_path(roms, core, kind, game)
    backup = "%s.bak-%s" % (os.path.basename(path), time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(time.time() if now is None else now)))
    shutil.copy2(path, os.path.join(os.path.dirname(path), backup))
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
    return {"written": True, "backup": backup, "size": len(data)}
