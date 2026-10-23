#!/usr/bin/env python3
"""Draws the RinkMaster app icon (rink look: navy backdrop, confetti, glowing red title, red/amber/teal stripes)
and writes Resources/AppIcon.icns (needs Pillow and macOS iconutil).

Usage: scripts/make_icon.py [--png out.png]   # --png only writes the 1024px master, no .icns
"""
import os, random, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RED, AMBER, TEAL = (229, 36, 43), (255, 176, 66), (46, 196, 182)
CONFETTI = [TEAL, (255, 105, 180), (150, 110, 220), AMBER, (80, 140, 255)]
S = 1024


def glow(layer, color, radius, strength=1.0):
    blur = layer.filter(ImageFilter.GaussianBlur(radius))
    if strength != 1.0:
        a = blur.getchannel("A").point(lambda v: min(255, int(v * strength)))
        blur.putalpha(a)
    return blur


def draw():
    rnd = random.Random(1984)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((40, 40, S - 40, S - 40), radius=210, fill=255)  # macOS icon grid margin

    # backdrop: deep navy to wine, with a soft spotlight from the top
    bg = Image.new("RGBA", (S, S))
    px = bg.load()
    for y in range(S):
        t = y / (S - 1)
        c = (int(8 + 70 * t * t), int(8 + 6 * t), int(24 + 18 * t))
        for x in range(S):
            px[x, y] = (*c, 255)
    spot = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(spot).polygon([(S * 0.42, 0), (S * 0.58, 0), (S * 0.92, S), (S * 0.08, S)], fill=(120, 150, 255, 46))
    bg = Image.alpha_composite(bg, spot.filter(ImageFilter.GaussianBlur(40)))

    # rink-carpet confetti
    conf = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cd = ImageDraw.Draw(conf)
    for _ in range(170):
        x, y = rnd.randint(40, S - 40), rnd.randint(40, S - 40)
        ln, ang = rnd.randint(14, 34), rnd.random() * 3.14159
        dx, dy = ln * 0.5 * __import__("math").cos(ang), ln * 0.5 * __import__("math").sin(ang)
        cd.line((x - dx, y - dy, x + dx, y + dy), fill=(*rnd.choice(CONFETTI), rnd.randint(70, 150)), width=rnd.randint(4, 7))
    bg = Image.alpha_composite(bg, conf)
    img.paste(bg, (0, 0), mask)

    # double red rules above the title
    rules = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rules)
    for y in (250, 268):
        rd.rectangle((190, y, S - 190, y + 6), fill=(*RED, 230))
    # title: "DLL" big, "ARCADE" smaller, in the Didot display serif
    didot = "/System/Library/Fonts/Supplemental/Didot.ttc"
    f_big = ImageFont.truetype(didot, 330, index=2)
    f_small = ImageFont.truetype(didot, 150, index=2)
    text = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(text)

    def centered(draw, y, s, font, fill):
        w = draw.textlength(s, font=font)
        draw.text(((S - w) / 2, y), s, font=font, fill=fill)

    centered(td, 250, "DLL", f_big, (*RED, 255))
    centered(td, 590, "ARCADE", f_small, (*RED, 255))
    # vertical gradient inside the letters: bright top to deep bottom
    grad = Image.new("RGBA", (S, S))
    gp = grad.load()
    for y in range(S):
        t = min(1.0, max(0.0, (y - 280) / 520))
        col = (int(255 - 40 * t), int(78 - 36 * t), int(78 - 30 * t))
        for x in range(S):
            gp[x, y] = (*col, 255)
    lettering = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    lettering.paste(grad, (0, 0), text.getchannel("A"))

    # stripes + tagline
    stripes = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stripes)
    for i, c in enumerate((RED, AMBER, TEAL)):
        sd.rectangle((170, 770 + i * 26, S - 170, 770 + i * 26 + 14), fill=(*c, 240))
    tag = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bebas = ImageFont.truetype(os.path.join(ROOT, "Sources/RinkMaster/Resources/Fonts/BebasNeue-Regular.ttf"), 70)
    td2 = ImageDraw.Draw(tag)
    centered(td2, 862, "S K A T E   T O W N   -   1 9 8 4", bebas, (*AMBER, 255))

    composite = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    composite = Image.alpha_composite(composite, glow(text, RED, 34, 1.4))
    composite = Image.alpha_composite(composite, glow(text, RED, 12, 1.0))
    composite = Image.alpha_composite(composite, glow(stripes, RED, 18, 0.9))
    composite = Image.alpha_composite(composite, rules)
    composite = Image.alpha_composite(composite, lettering)
    composite = Image.alpha_composite(composite, stripes)
    composite = Image.alpha_composite(composite, tag)
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    clipped.paste(composite, (0, 0), mask)
    img = Image.alpha_composite(img, clipped)

    # glowing red frame with an amber inner line, like the cabinet's screen frame
    frame = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle((40, 40, S - 40, S - 40), radius=210, outline=(*RED, 255), width=14)
    img = Image.alpha_composite(img, Image.composite(glow(frame, RED, 16, 1.0), Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))
    fd.rounded_rectangle((70, 70, S - 70, S - 70), radius=182, outline=(*AMBER, 150), width=3)
    img = Image.alpha_composite(img, frame)
    return img


def main():
    master = draw()
    if "--png" in sys.argv:
        out = sys.argv[sys.argv.index("--png") + 1]
        master.save(out)
        print("wrote", out)
        return
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 128, 256, 512):
            master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
            master.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
        out = os.path.join(ROOT, "Resources", "AppIcon.icns")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
        print("wrote", out)


if __name__ == "__main__":
    main()
