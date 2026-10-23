#!/usr/bin/env python3
"""Generates the artwork for the EmulationStation theme themes/dll-arcade (1920x1080, landscape).

Same palette and look as the app and the Attract-Mode "rink" layout:
near-black navy fading to maroon, soft spotlight beams, carpet confetti, and the red/amber/teal stripe band.
Writes themes/dll-arcade/art/{bg,frame,selector}.png (the logo and fonts are copied from the rink layout / the app).

Usage: scripts/make-es-theme-assets.py [-h]     (needs Pillow: python3 -m pip install pillow)
"""
import os
import random
import sys

if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
    print(__doc__)
    sys.exit(0)

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "themes", "dll-arcade", "art")
W, H = 1920, 1080
RED, AMBER, TEAL = (229, 36, 43), (255, 176, 66), (46, 196, 182)
PINK, PURPLE, BLUE = (255, 79, 147), (123, 44, 191), (80, 120, 255)
CONFETTI = [TEAL, PINK, PURPLE, AMBER, BLUE]
STOPS = [(0.0, (4, 3, 10)), (0.6, (12, 6, 24)), (1.0, (22, 6, 16))]
HORIZON = 930  # the stripe band; the floor (maroon) is below it and carries the help prompts


def gradient_at(t):
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1:
            u = (t - t0) / (t1 - t0)
            return tuple(int(a + (b - a) * u) for a, b in zip(c0, c1))
    return STOPS[-1][1]


def background():
    rnd = random.Random(1984)
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        d.line([(0, y), (W, y)], fill=gradient_at(y / (H - 1)))
    # floor: a warmer maroon below the horizon
    floor = Image.new("RGB", (W, H - HORIZON), (80, 16, 24))
    mask = Image.linear_gradient("L").resize((W, H - HORIZON)).point(lambda v: int(v * 0.95))
    img.paste(floor, (0, HORIZON), mask)

    # spotlight beams from the top
    beams = Image.new("RGB", (W, H), (0, 0, 0))
    bd = ImageDraw.Draw(beams)
    for cx, color in ((330, TEAL), (960, AMBER), (1590, PINK)):
        bd.polygon([(cx - 40, 0), (cx + 40, 0), (cx + 330, HORIZON), (cx - 330, HORIZON)], fill=tuple(int(c * 0.09) for c in color))
    beams = beams.filter(ImageFilter.GaussianBlur(70))
    img = ImageChops.add(img, beams)

    # confetti
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for _ in range(750):
        x, y = rnd.randrange(W), rnd.randrange(H)
        color = rnd.choice(CONFETTI)
        length, thick = rnd.randrange(8, 26), rnd.randrange(2, 5)
        piece = Image.new("RGBA", (length, thick), color + (rnd.randrange(35, 90),))
        layer.alpha_composite(piece.rotate(rnd.randrange(180), expand=True), (min(x, W - 30), min(y, H - 30)))
    img = Image.alpha_composite(img.convert("RGBA"), layer)

    # stripe band with a soft glow
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for i, color in enumerate((RED, AMBER, TEAL)):
        gd.rectangle([0, HORIZON + i * 14, W, HORIZON + i * 14 + 11], fill=color + (255,))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(9)))
    img = Image.alpha_composite(img, glow)
    return img.convert("RGB")


def frame(w, h, border=6):
    """A glowing red frame with a transparent middle."""
    pad = 36
    img = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.rounded_rectangle([pad, pad, pad + w, pad + h], radius=14, outline=RED + (255,), width=border + 6)
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(14)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([pad, pad, pad + w, pad + h], radius=14, outline=RED + (255,), width=border)
    d.rounded_rectangle([pad + border, pad + border, pad + w - border, pad + h - border], radius=10, outline=AMBER + (160,), width=2)
    return img


def selector(w, h):
    """The highlighted row: a red glow fading to the right with an amber tick on the left."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    for x in range(w):
        a = int(150 * max(0.0, 1 - x / w) ** 0.7)
        for y in range(h):
            px[x, y] = RED + (a,)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 6, 7, h - 7], fill=AMBER + (255,))
    return img


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    background().save(os.path.join(OUT, "bg.png"), optimize=True)
    frame(880, 500).save(os.path.join(OUT, "frame.png"), optimize=True)
    selector(860, 66).save(os.path.join(OUT, "selector.png"), optimize=True)
    print("wrote bg.png, frame.png, selector.png to", os.path.normpath(OUT))
