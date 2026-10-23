"""Builds a fake RetroPie tree (roms + configs) shaped like the real cabinets, in a temp dir."""
import os
import tempfile


def write(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def make_tree():
    """Returns (root, roms, configs). Caller removes root with shutil.rmtree."""
    root = tempfile.mkdtemp(prefix="rinkd-")
    roms = os.path.join(root, "roms")
    cfgs = os.path.join(root, "configs")
    # mame-libretro: zips are games; cfg/state/art/core folders are not
    for name in ("galaga.zip", "tempest.zip"):
        write(os.path.join(roms, "mame-libretro", name), b"zipdata")
    write(os.path.join(roms, "mame-libretro", "galaga.zip.cfg"))
    write(os.path.join(roms, "mame-libretro", "mk2.state"))
    os.makedirs(os.path.join(roms, "mame-libretro", "snap"))
    os.makedirs(os.path.join(roms, "mame-libretro", "mame2003"))
    # daphne: *.daphne folders
    os.makedirs(os.path.join(roms, "daphne", "lair.daphne"))
    os.makedirs(os.path.join(roms, "daphne", "roms"))
    # atari2600: rom files, notes ignored
    write(os.path.join(roms, "atari2600", "Adventure.bin"))
    write(os.path.join(roms, "atari2600", "notes.txt"))
    os.makedirs(os.path.join(roms, "atari2600", "snap"))
    # nes: only art -> no games, must be omitted
    os.makedirs(os.path.join(roms, "nes", "snap"))
    # configs
    write(os.path.join(cfgs, "mame-libretro", "emulators.cfg"),
          b'lr-mame2003 = "retroarch -L a %ROM%"\ndefault = "lr-mame2010"\nlr-mame2010 = "retroarch -L b %ROM%"\n')
    write(os.path.join(cfgs, "daphne", "emulators.cfg"), b'daphne = "daphne %ROM%"\ndefault = "daphne"\n')
    write(os.path.join(cfgs, "atari2600", "emulators.cfg"), b'default = "lr-stella2014"\n')
    write(os.path.join(cfgs, "all", "emulators.cfg"),
          b'mame-libretro_tempest = "lr-mame2003"\natari2600_Adventure = "stella"\n')
    # art, saves and scores for galaga (used by the remove tests); tempest has only a marquee
    for sub in ("snap", "wheel", "marquee", "flyer"):
        write(os.path.join(roms, "mame-libretro", sub, "galaga.png"))
    write(os.path.join(roms, "mame-libretro", "snap", "galaga.mp4"))
    write(os.path.join(roms, "mame-libretro", "marquee", "tempest.png"))
    write(os.path.join(roms, "mame-libretro", "mk2.state1"))
    write(os.path.join(roms, "mame-libretro", "galaga.state"))
    write(os.path.join(roms, "mame-libretro", "mame2010", "cfg", "galaga.cfg"))
    write(os.path.join(roms, "mame-libretro", "mame2010", "hi", "galaga.hi"))
    write(os.path.join(roms, "mame-libretro", "mame2010", "nvram", "galaga.nv"))
    write(os.path.join(roms, "mame-libretro", "mame2003", "hi", "tempest.hi"))
    return root, roms, cfgs


def make_emulators(root):
    """Configs whose commands point at fake binaries under root/opt (some missing). Returns configs path."""
    opt = os.path.join(root, "opt")
    cfgs = os.path.join(root, "cfgs-emu")
    write(os.path.join(opt, "bin", "retroarch"))
    os.chmod(os.path.join(opt, "bin", "retroarch"), 0o755)
    write(os.path.join(opt, "cores", "mame2010_libretro.so"))        # installed
    # mame2003 core is NOT created -> not installed
    write(os.path.join(opt, "bin", "daphne"))
    os.chmod(os.path.join(opt, "bin", "daphne"), 0o755)
    ra = os.path.join(opt, "bin", "retroarch")
    write(os.path.join(cfgs, "mame-libretro", "emulators.cfg"), (
        'lr-mame2010 = "%s -L %s --config /c %%ROM%%"\n' % (ra, os.path.join(opt, "cores", "mame2010_libretro.so")) +
        'lr-mame2003 = "%s -L %s --config /c %%ROM%%"\n' % (ra, os.path.join(opt, "cores", "mame2003_libretro.so")) +
        'default = "lr-mame2010"\n').encode())
    write(os.path.join(cfgs, "daphne", "emulators.cfg"), ('daphne = "%s %%ROM%%"\ndefault = "daphne"\n' % os.path.join(opt, "bin", "daphne")).encode())
    write(os.path.join(cfgs, "atari2600", "emulators.cfg"), b'stella = "/no/such/stella -x %ROM%"\ndefault = "stella"\n')
    write(os.path.join(cfgs, "all", "emulators.cfg"), b'mame-libretro_tempest = "lr-mame2003"\n')
    return cfgs
