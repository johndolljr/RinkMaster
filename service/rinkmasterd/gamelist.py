"""EmulationStation game lists: add or update games (name, description, artwork) so ES shows them with their art.

Writes `<configs>/all/emulationstation/gamelists/<system>/gamelist.xml`, the per-user list ES reads when the ROM folder has none.
Entries are merged by `<path>`; fields we are not given and other games are left as they are. A `.bak` copy of the previous file is
kept and the new file replaces it atomically. Applying the same entries twice changes nothing.
"""
from __future__ import annotations

import os
import re
import shutil
import tempfile
import xml.etree.ElementTree as ET
from typing import List

SYSTEM_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]*$")
FIELDS = ("name", "desc", "image", "thumbnail", "marquee", "video", "releasedate", "developer", "publisher", "genre", "hidden")
PATH_FIELDS = ("image", "thumbnail", "marquee", "video")
MAX_GAMES = 1000
MAX_FIELD = 8000


class BadRequest(Exception):
    pass


def _check_entry(entry) -> dict:
    if not isinstance(entry, dict):
        raise BadRequest("each game must be an object")
    path = entry.get("path")
    if not isinstance(path, str) or not path.startswith("./") or ".." in path or "\n" in path or len(path) > 300:
        raise BadRequest("each game needs a path like ./name.zip")
    clean = {"path": path}
    for field in FIELDS:
        value = entry.get(field)
        if value is None:
            continue
        if not isinstance(value, str) or len(value) > MAX_FIELD:
            raise BadRequest("invalid %s" % field)
        if field in PATH_FIELDS and value and (not value.startswith("./") or ".." in value or "\n" in value):
            raise BadRequest("%s must be a ./relative path" % field)
        clean[field] = value
    return clean


def gamelist_path(configs: str, system) -> str:
    if not isinstance(system, str) or not SYSTEM_RE.match(system) or ".." in system:
        raise BadRequest("invalid system name")
    return os.path.join(configs, "all", "emulationstation", "gamelists", system, "gamelist.xml")


MEDIA_PROBES = (  # (field, folder, extensions) in priority order; the first file found fills the field
    ("image", "flyer", ("png", "jpg", "jpeg")), ("image", "boxart", ("png", "jpg", "jpeg")),
    ("marquee", "marquee", ("png", "jpg", "jpeg")), ("marquee", "wheel", ("png", "jpg", "jpeg")),
    ("thumbnail", "snap", ("png", "jpg", "jpeg")),
)  # No video: one <video> in a system's list switches ES to its video view, and playing them crashed ES on the xarcade.


def find_media(roms: str, system: str, path: str) -> dict:
    """The art that really exists beside a ROM: ./flyer/<stem>.png as the image, ./snap/<stem>.mp4 as the video, and so on."""
    stem = os.path.splitext(os.path.basename(path))[0]
    found: dict = {}
    for field, folder, exts in MEDIA_PROBES:
        if field in found:
            continue
        for ext in exts:
            if os.path.isfile(os.path.join(roms, system, folder, "%s.%s" % (stem, ext))):
                found[field] = "./%s/%s.%s" % (folder, stem, ext)
                break
    return found


def upsert(configs: str, system, games, dry_run: bool = False, roms: str = "", auto_media: bool = False,
           only_missing: bool = False) -> dict:
    """auto_media: look for each game's art in the ROM folder and fill image/marquee/video/thumbnail from what exists.
    only_missing: keep whatever the list already has for a game and fill in only the empty fields."""
    path = gamelist_path(configs, system)
    if not isinstance(games, list) or not games or len(games) > MAX_GAMES:
        raise BadRequest("games must be a list of 1 to %d entries" % MAX_GAMES)
    entries: List[dict] = [_check_entry(g) for g in games]

    if os.path.isfile(path):
        try:
            tree = ET.parse(path)
        except ET.ParseError:
            raise BadRequest("the existing gamelist.xml cannot be read; not touching it")
        root = tree.getroot()
    else:
        root = ET.Element("gameList")
    by_path = {(g.findtext("path") or ""): g for g in root.findall("game")}

    added = updated = 0
    for entry in entries:
        game = by_path.get(entry["path"])
        is_new = game is None
        if is_new:
            game = ET.SubElement(root, "game")
            ET.SubElement(game, "path").text = entry["path"]
            by_path[entry["path"]] = game
        touched = False
        if auto_media:
            entry = dict(entry)
            for field, value in find_media(roms, system, entry["path"]).items():
                entry.setdefault(field, value)
        for field in FIELDS:
            if field not in entry or (only_missing and not entry[field]):
                continue
            node = game.find(field)
            if node is None:
                node = ET.SubElement(game, field)
                node.text = entry[field]
                touched = True
            elif (node.text or "") != entry[field] and not (only_missing and (node.text or "").strip()):
                node.text = entry[field]
                touched = True
        if is_new:
            added += 1
        elif touched:
            updated += 1
    changed = bool(added or updated)
    backup = None
    if changed and not dry_run:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.isfile(path):
            backup = path + ".bak"
            shutil.copy2(path, backup)
        ET.indent(root)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".gamelist-")
        try:
            with os.fdopen(fd, "wb") as f:
                ET.ElementTree(root).write(f, encoding="utf-8", xml_declaration=True)
            if os.path.isfile(path):
                shutil.copymode(path, tmp)
            else:
                os.chmod(tmp, 0o644)
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
    return {"system": system, "file": path, "added": added, "updated": updated, "changed": changed,
            "dryRun": dry_run, "backup": backup}
