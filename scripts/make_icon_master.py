#!/usr/bin/env python3
"""Composes the 1024x1024 app-icon master: the wren on the brand blue field.

Writes Resources/ChirpMascot.png (what scripts/make_icon.sh rasterises into
the .icns) and Resources/Icon/chirp_icon_master.png (the design copy).

The bird itself comes from the pet's own native 32x32 sprite, scaled with
nearest-neighbour so it stays true pixel art rather than a blurred upscale
— same character, same ten-colour palette, same art as the thing that sits
on your desktop.

    python3 scripts/make_icon_master.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SPRITE = ROOT / "Sources/Chirp/Resources/Pet/wren_idle_00.png"
OUTPUTS = [ROOT / "Resources/ChirpMascot.png",
           ROOT / "Resources/Icon/chirp_icon_master.png"]

SIZE = 1024
# The brand field, sampled from Resources/Promo/*.png so the icon and the
# promo art can't drift apart. Deliberately not the app's own cream
# `Palette.paper`: the interface is warm paper, the brand mark is the
# wren's own sky blue — a mascot carrying its own identity rather than
# being reskinned in the host UI's colours.
FIELD_COLOUR = (94, 158, 240, 255)
# Apple's icon grid: the rounded square occupies 824 of the 1024 canvas,
# leaving the margin the system expects for shadows and alignment with
# other icons in the Dock and Finder.
FIELD = 824
# Supersample, then downscale — the squircle's curve needs it, and PIL has
# no anti-aliased path fill.
SS = 4


def squircle(size: int, radius_exponent: float = 5.0) -> Image.Image:
    """A superellipse mask — Apple's continuous-corner shape, not a plain
    rounded rectangle, whose circular corners visibly kink where they meet
    the straight edges at this scale."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    half = size / 2
    for y in range(size):
        # Solve the superellipse for x at this row: |x/a|^n + |y/b|^n = 1.
        ny = abs((y + 0.5 - half) / half)
        if ny >= 1:
            continue
        nx = (1 - ny ** radius_exponent) ** (1 / radius_exponent)
        dx = nx * half
        draw.line([(half - dx, y), (half + dx, y)], fill=255)
    return mask


def main() -> None:
    bird = Image.open(SPRITE).convert("RGBA")

    canvas = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    field = Image.new("RGBA", (FIELD * SS, FIELD * SS), FIELD_COLOUR)
    field.putalpha(squircle(FIELD * SS))
    offset = (SIZE - FIELD) // 2 * SS
    canvas.alpha_composite(field, (offset, offset))
    canvas = canvas.resize((SIZE, SIZE), Image.LANCZOS)

    # Crop to the bird's own opaque bounds first. The 32x32 frame has
    # uneven padding (the sprite is positioned for animation, not for
    # framing), so centring the frame leaves the bird visibly off-centre.
    bird = bird.crop(bird.getbbox())

    # Scale by a whole number so every source pixel stays exactly square —
    # a fractional factor makes some icon "pixels" a row wider than their
    # neighbours, which is glaring in flat pixel art. Pick the largest
    # integer factor that still leaves a comfortable margin inside the
    # field.
    target = FIELD * 0.66
    scale = max(1, int(target // max(bird.width, bird.height)))
    bird = bird.resize((bird.width * scale, bird.height * scale), Image.NEAREST)

    # Centre, then lift slightly: the wren's cocked tail carries a lot of
    # its height but very little of its visual weight, so a geometric
    # centre reads as sagging toward the bottom of the field.
    x = (SIZE - bird.width) // 2
    y = (SIZE - bird.height) // 2 - int(SIZE * 0.02)
    canvas.alpha_composite(bird, (x, y))

    for out in OUTPUTS:
        out.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(out)
        print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
