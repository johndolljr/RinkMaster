#!/usr/bin/env python3
"""Draws one diagram per emulator of what each X-Arcade panel button does on the xarcade cabinet.

Usage: scripts/make-button-diagram.py [-h]        (needs Pillow)
Writes docs/xarcade-buttons-{menus,mame,atari,daphne}.png. Layout as the player sees it, joystick on the left.
Button numbers (js0-js7) are the gamepad's button numbers; their positions were measured from the panel.
"""
import os
import sys

if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
    print(__doc__)
    sys.exit(0)
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "themes", "dll-arcade", "art")
OUT = os.path.join(HERE, "..", "docs")
W, H = 1700, 1180
BG, PANEL = (10, 6, 22), (26, 22, 40)
RED, AMBER, TEAL, LAV, CREAM, WHITE, DIM = (229, 36, 43), (255, 176, 66), (46, 196, 182), (150, 130, 190), (255, 230, 205), (255, 255, 255), (80, 72, 104)
BEBAS, BUNGEE = "BebasNeue-Regular.ttf", "Bungee-Regular.ttf"

# physical layout: (x, y) of each big button, by js number (rows are top / middle / bottom, left to right)
POS = {0: (560, 330), 1: (730, 310), 2: (900, 330), 3: (590, 510), 4: (760, 510), 5: (930, 510), 6: (650, 690), 7: (830, 690)}


def font(name, size):
    return ImageFont.truetype(os.path.join(ART, name), size)


class Canvas:
    def __init__(self):
        self.img = Image.new("RGB", (W, H), BG)
        self.d = ImageDraw.Draw(self.img)

    def text(self, xy, s, size, fill=WHITE, face=BEBAS, anchor="mm"):
        self.d.text(xy, s, font=font(face, size), fill=fill, anchor=anchor)

    def lines(self, x, y, s, size, fill, gap=None, maxw=170):
        """Centered text wrapped to maxw pixels, first line at y."""
        f = font(BEBAS, size)
        words, rows, cur = s.split(), [], ""
        for w in words:
            t = (cur + " " + w).strip()
            if f.getlength(t) <= maxw or not cur:
                cur = t
            else:
                rows.append(cur); cur = w
        if cur:
            rows.append(cur)
        for i, r in enumerate(rows):
            self.text((x, y + i * (gap or size + 3)), r, size, fill)

    def circle(self, cx, cy, r, color, fill=(14, 12, 24), ring=6):
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse([cx - r, cy - r, cx + r, cy + r], outline=color + (255,), width=ring + 8)
        self.img = Image.alpha_composite(self.img.convert("RGBA"), layer.filter(ImageFilter.GaussianBlur(10))).convert("RGB")
        self.d = ImageDraw.Draw(self.img)
        self.d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill, outline=color, width=ring)


def diagram(filename, title, subtitle, buttons, start, select, spinner, trackball, joystick, quit_lines, notes):
    c = Canvas()
    c.text((W // 2, 60), title, 58, RED, BUNGEE)
    c.text((W // 2, 118), subtitle, 28, LAV)
    c.d.rounded_rectangle([40, 160, 1660, 790], radius=30, fill=PANEL, outline=(70, 60, 100), width=3)
    c.d.rounded_rectangle([40, 810, 1000, 1010], radius=22, fill=PANEL, outline=(70, 60, 100), width=3)
    c.text((520, 1040), "FRONT EDGE (facing you)", 26, LAV)

    c.circle(250, 480, 95, LAV)
    c.d.ellipse([205, 435, 295, 525], fill=(40, 36, 60), outline=LAV, width=4)
    c.text((250, 620), "JOYSTICK", 34, CREAM)
    c.lines(250, 660, joystick, 24, CREAM, maxw=300)

    for js, (x, y) in POS.items():
        role, color = buttons.get(js, ("", DIM))
        c.circle(x, y, 52, color)
        c.text((x, y), "js%d" % js, 38, WHITE if role else DIM, BUNGEE)
        if role:
            c.lines(x, y + 78, role, 25, color if color != DIM else CREAM, maxw=165)

    c.circle(1130, 250, 70, (190, 190, 200), ring=5, fill=(120, 120, 130))
    c.text((1130, 250), "SPINNER", 28, BG)
    c.lines(1130, 345, spinner, 24, CREAM, maxw=230)

    for x, label in ((1420, "1P"), (1550, "2P")):
        c.circle(x, 215, 45, CREAM, ring=5, fill=(215, 205, 190))
        c.text((x, 215), label, 40, BG, BUNGEE)
    c.text((1485, 295), "START", 34, AMBER, BUNGEE)
    c.lines(1485, 335, start, 24, CREAM, maxw=230)

    c.circle(1330, 570, 125, (200, 200, 190), ring=6, fill=(170, 170, 160))
    c.text((1330, 570), "TRACKBALL", 32, BG)
    c.lines(1330, 725, trackball, 24, CREAM, maxw=300)

    for x, label in ((300, "LEFT"), (500, "RIGHT")):
        c.circle(x, 900, 45, CREAM, ring=5, fill=(215, 205, 190))
        c.text((x, 900), label, 24, BG)
    c.text((750, 880), "SELECT", 34, AMBER, BUNGEE)
    c.lines(750, 925, select, 24, CREAM, maxw=230)

    c.d.rounded_rectangle([1040, 810, 1660, 1150], radius=22, fill=PANEL, outline=RED, width=3)
    c.text((1350, 850), "TO QUIT", 38, RED, BUNGEE)
    y = 905
    for s, color in quit_lines:
        c.text((1350, y), s, 26, color)
        y += 40
    y = 1085
    for s in notes:
        c.text((520, y), s, 23, LAV)
        y += 34
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, filename)
    c.img.save(path, optimize=True)
    print("wrote", os.path.normpath(path))


QUIT_RETROARCH = [("HOLD SELECT + START (either START)", WHITE), ("Select = either front button.", CREAM), ("Hold, then release. Game closes", CREAM), ("and you are back at the game list.", CREAM)]
QUIT_STANDALONE = [("HOLD FRONT-LEFT SELECT + 1P", WHITE), ("for 1.5 seconds.", CREAM), ("(Front-left = the one closest", CREAM), ("to the player, on the left.)", CREAM)]

diagram("xarcade-buttons-menus.png", "MENUS  -  EMULATIONSTATION", "BROWSING THE GAME LISTS (NOT INSIDE A GAME)",
        {0: ("A: pick / launch", AMBER), 2: ("B: back", TEAL), 3: ("Page up (jump back)", LAV), 4: ("Y: favourite", LAV), 5: ("X: random game", LAV)},
        "Opens the ES menu", "No use in lists", "Not used in menus", "Not used in menus", "Move through the list and systems",
        [("INSIDE A GAME: see that game's page", WHITE), ("MAME: SELECT + START", CREAM), ("Atari: front-left + 1P, 1.5 s", CREAM)],
        ["Buttons come from ES's own input setup", "(es_input.cfg for the X-Arcade pads)."])

diagram("xarcade-buttons-mame.png", "MAME GAMES  -  RETROARCH", "TEMPEST, ARKANOID, GALAGA, ALL THE ARCADE GAMES",
        {4: ("Button 1  -  FIRE", RED), 3: ("Button 2  -  Superzapper / jump", RED), 1: ("Button 3", TEAL), 0: ("Button 4", TEAL), 2: ("Button 5", TEAL), 5: ("Button 6", TEAL)},
        "Starts a game (1P or 2P)", "COIN: puts a credit in", "Dial games (Tempest, Arkanoid)", "Missile Command, Centipede...", "8-way / 4-way as the game needs",
        QUIT_RETROARCH, ["js6 and js7 are spare in MAME games.", "Spinner games point at the smoothed spinner."])

diagram("xarcade-buttons-atari.png", "ATARI 2600  -  STELLA", "BREAKOUT, KABOOM, CIRCUS ATARI, PITFALL, ...",
        {0: ("FIRE (serve ball / shoot)", AMBER)},
        "RESET: starts a game", "Atari SELECT: changes the game variation", "PADDLE for Breakout, Kaboom!, Circus...", "Also moves a paddle: avoid it", "Joystick games: move / aim",
        QUIT_STANDALONE, ["Only js0 is mapped to fire.", "The 2600 console switches live on START and SELECT."])

diagram("xarcade-buttons-daphne.png", "LASER DISC  -  DAPHNE", "DRAGON'S LAIR, SPACE ACE  (FROM DAPHNE'S OWN SETTINGS)",
        {0: ("Button 1  -  SWORD / action", RED), 1: ("Button 2", TEAL), 2: ("Button 3", TEAL), 6: ("QUIT the game", AMBER)},
        "START: begins a game", "COIN: puts a credit in", "Not used", "Not used", "Move Dirk / pick a direction",
        [("PRESS js6 (bottom-left big button)", WHITE), ("to quit Daphne.", CREAM), ("The SELECT + START combo", CREAM), ("is not used here.", CREAM)],
        ["From dapinput.ini; confirmed by loading, not yet", "by playing. Tell me if a button is wrong."])
