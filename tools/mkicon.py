#!/usr/bin/env python3
"""Build the Onion Apps-menu icon from the master logo.

    tools/mkicon.py

Onion's MainUI reads the `icon` path out of App/PocketFlex/config.json and
blits it in the menu. Every icon it ships is **74x74 RGBA** -- checked across
the whole of Icons/Default/app -- and the house style is a rounded rect with a
light outline that fills most of the square, so the glyph reads against any
theme background. Ours is dark on dark, so the outline is doing real work here
and is not decoration.

Two icons come out of this, both 74x74:

    icon.png       the whole logo, mark over wordmark, fitted to the square
    icon-mark.png  the pocket alone, which is all that survives at this size

config.json picks one. See CHANGELOG v0.2.2.
"""

import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "image_assets", "PocketFlex_SplashLoadingLogo.png")
OUT = os.path.join(ROOT, "App", "PocketFlex", "res")

SIZE = 74
RADIUS = 15
# Supersample, then downscale once at the end: a 74px rounded corner drawn
# directly is a staircase, and the logo has a lot of fine detail to lose.
SS = 8

# The master is 350x483 on opaque black. These are the content boxes measured
# off it -- the mark is the pocket, the whole box takes in POCKET/FLEX below.
BOX_WHOLE = (6, 6, 340, 479)
BOX_MARK = (79, 6, 264, 261)

# The tile has to be the master's own black exactly, or the artwork's square
# background shows as a seam inside the rounded corners.
TILE = (0, 0, 0, 255)
EDGE = (232, 232, 234, 255)


def build(box, pad, out_name):
    src = Image.open(SRC).convert("RGB").crop(box)

    big = SIZE * SS
    icon = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, big - 1, big - 1), radius=RADIUS * SS, fill=255
    )

    tile = Image.new("RGBA", (big, big), TILE)
    icon.paste(tile, (0, 0), mask)

    # Fit inside the tile without cropping: the logo keeps its aspect, so the
    # tall whole-logo version simply leaves more tile showing left and right.
    inner = big - 2 * pad * SS
    w, h = src.size
    scale = min(inner / w, inner / h)
    art = src.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    icon.paste(art, ((big - art.width) // 2, (big - art.height) // 2))

    # Re-apply the mask so the artwork's own black corners are clipped to the
    # rounded tile rather than squaring it off again.
    icon.putalpha(mask)

    ImageDraw.Draw(icon).rounded_rectangle(
        (SS, SS, big - SS - 1, big - SS - 1), radius=RADIUS * SS - SS,
        outline=EDGE, width=2 * SS,
    )

    icon = icon.resize((SIZE, SIZE), Image.LANCZOS)
    path = os.path.join(OUT, out_name)
    icon.save(path)
    print("%-16s %dx%d  %d bytes" % (out_name, icon.width, icon.height,
                                     os.path.getsize(path)))


if __name__ == "__main__":
    build(BOX_WHOLE, 6, "icon.png")
    build(BOX_MARK, 8, "icon-mark.png")
