#!/usr/bin/env python3
"""Turns on each game's "Cabinet: Cocktail" DIP switch on a cocktail-table cabinet, so the picture flips for player 2.

Usage:
  scripts/set-cocktail-dips.py USER@HOST [--dry-run] [--revert] [--data data/arcade2-cocktail-dips.json]

The data file (made from the master's MAME with `-listxml`) lists, per installed game, its cocktail DIP switch (tag, mask, the
default and the cocktail value) and which libretro core runs it. For the XML-config cores (lr-mame2010 / 2015 / 2016) this writes
`<port tag=".." type="DIPSWITCH" mask=".." defvalue=".." value=".."/>` into `<roms>/mame-libretro/<core>/cfg/<game>.cfg`, keeping
whatever else the file holds (coin counters, button mappings). lr-mame2003 keeps binary configs and is skipped. The cfg folders are
backed up first to `cfg.bak-cocktail`; --revert puts them back. Needs key-based SSH.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
    print(__doc__)
    sys.exit(0)
target = sys.argv[1]
dry = "--dry-run" in sys.argv
revert = "--revert" in sys.argv
data_path = sys.argv[sys.argv.index("--data") + 1] if "--data" in sys.argv else os.path.join(os.path.dirname(__file__), "..", "data", "arcade2-cocktail-dips.json")
ROMS = "/home/pi/RetroPie/roms/mame-libretro"
# Games where both players play at once on a shared screen: flipping the picture for player 2 would be wrong, so leave them alone.
SIMULTANEOUS = {"ddragon", "ddragon2", "ddragon2u", "ddragonub", "88games", "hyperspt", "trackfld"}
CORE_DIR = {"lr-mame2010": "mame2010", "lr-mame2015": "mame2015", "lr-mame2016": "mame2016"}
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", target]


def run(cmd):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True)


def merge(cfg_text, game, dip):
    """The cfg XML with the DIP entry set (replacing any entry for the same switch)."""
    if cfg_text:
        root = ET.fromstring(cfg_text.lstrip("﻿").encode())
    else:
        root = ET.Element("mameconfig", version="10")
    system = next((s for s in root.findall("system") if s.get("name") == game), None)
    if system is None:
        system = ET.SubElement(root, "system", name=game)
    inp = system.find("input")
    if inp is None:
        inp = ET.SubElement(system, "input")
    for p in list(inp.findall("port")):
        if p.get("type") == "DIPSWITCH" and p.get("tag") == dip["tag"] and p.get("mask") == dip["mask"]:
            inp.remove(p)
    ET.SubElement(inp, "port", tag=dip["tag"], type="DIPSWITCH", mask=dip["mask"], defvalue=dip["dvalue"], value=dip["cvalue"])
    ET.indent(root, space="    ")
    return "﻿" + ET.tostring(root, encoding="unicode", xml_declaration=False).join(['<?xml version="1.0"?>\n', "\n"])


data = json.load(open(data_path))
dips, cores = data["dips"], data["cores"]
plan = []
skipped = []
for game, entries in sorted(dips.items()):
    core = cores.get(game) or "lr-mame2010"
    entry = next((e for e in entries if e["dip"].lower() in ("cabinet", "control panel") and ":" not in e["tag"] and "/" not in e["tag"]), None)
    if game in SIMULTANEOUS:
        skipped.append((game, "both players play at once"))
    elif core not in CORE_DIR:
        skipped.append((game, "binary config (%s)" % core))
    elif entry is None or entry["dvalue"] is None:
        skipped.append((game, "switch not a plain cabinet setting"))
    else:
        plan.append((game, CORE_DIR[core], entry))

if revert:
    for core in sorted(set(c for _, c, _ in plan)):
        r = run("cd %s/%s && [ -d cfg.bak-cocktail ] && rm -rf cfg && cp -a cfg.bak-cocktail cfg && echo restored %s" % (ROMS, core, core))
        print(r.stdout.strip() or "no backup for " + core)
    sys.exit(0)

print("%d games get the cocktail switch; skipped %d:" % (len(plan), len(skipped)))
for game, why in skipped:
    print("   skip %-12s %s" % (game, why))
if dry:
    for game, core, e in plan:
        print("   %-12s %-8s %s[%s/%s]: %s=%s -> %s=%s" % (game, core, e["dip"], e["tag"], e["mask"], e["default"], e["dvalue"], e["cocktail"], e["cvalue"]))
    sys.exit(0)

for core in sorted(set(c for _, c, _ in plan)):
    run("cd %s/%s && [ -d cfg ] && [ ! -d cfg.bak-cocktail ] && cp -a cfg cfg.bak-cocktail; mkdir -p cfg; true" % (ROMS, core))
work = tempfile.mkdtemp()
done = 0
for game, core, e in plan:
    cur = run("cat %s/%s/cfg/%s.cfg 2>/dev/null" % (ROMS, core, game)).stdout
    text = merge(cur, game, e)
    local = os.path.join(work, core)
    os.makedirs(local, exist_ok=True)
    path = os.path.join(local, game + ".cfg")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    ET.parse(path)  # must be valid XML
for core in sorted(set(c for _, c, _ in plan)):
    subprocess.run(["rsync", "-rt", "-e", "ssh -o BatchMode=yes", os.path.join(work, core) + "/", "%s:%s/%s/cfg/" % (target, ROMS, core)], check=True)
    done += len(os.listdir(os.path.join(work, core)))
shutil.rmtree(work, ignore_errors=True)
run("sync")
print("wrote %d cfg files (backups: cfg.bak-cocktail in each core folder)" % done)
