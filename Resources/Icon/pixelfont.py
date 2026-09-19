"""A tiny, hand-authored 5x7 pixel bitmap font — self-drawn, same spirit
as the wren art, so there's no font file/licence to worry about and it's
genuinely pixel art rather than a smooth face dressed up to look blocky.
Only the glyphs actually used in the brand artwork are defined; add more
rows to GLYPHS as needed.
"""
from PIL import Image, ImageDraw

# Each glyph: 7 rows, top to bottom. '#' = lit, '.' = empty. Widths vary
# (I/period/space/dot are narrower) — each glyph carries its own width.
GLYPHS = {
    "C": [
        ".###.",
        "#...#",
        "#....",
        "#....",
        "#....",
        "#...#",
        ".###.",
    ],
    "H": [
        "#...#",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    ],
    "I": [
        ".###.",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        ".###.",
    ],
    "R": [
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#.#..",
        "#..#.",
        "#...#",
    ],
    "P": [
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#....",
        "#....",
        "#....",
    ],
    "S": [
        ".####",
        "#....",
        "#....",
        ".###.",
        "....#",
        "....#",
        "####.",
    ],
    "E": [
        "#####",
        "#....",
        "#....",
        "####.",
        "#....",
        "#....",
        "#####",
    ],
    "T": [
        "#####",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
    ],
    "O": [
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    ],
    "X": [
        "#...#",
        "#...#",
        ".#.#.",
        "..#..",
        ".#.#.",
        "#...#",
        "#...#",
    ],
    " ": [
        "...",
        "...",
        "...",
        "...",
        "...",
        "...",
        "...",
    ],
    "-": [
        "...",
        "...",
        "...",
        "###",
        "...",
        "...",
        "...",
    ],
    "·": [  # middle dot, used as a word separator in the tagline
        "...",
        "...",
        "...",
        ".#.",
        "...",
        "...",
        "...",
    ],
}


def text_size(text, px, spacing=1):
    if not text:
        return 0, 0
    w = 0
    for i, ch in enumerate(text):
        glyph = GLYPHS[ch]
        gw = len(glyph[0])
        w += gw
        if i < len(text) - 1:
            w += spacing
    return w * px, 7 * px


def draw_pixel_text(img, xy, text, px, fill, spacing=1):
    """Draws `text` onto a PIL RGBA image at (x, y) top-left, px pixels
    per font-pixel, using GLYPHS. Returns the (width, height) drawn."""
    d = ImageDraw.Draw(img)
    x0, y0 = xy
    x = x0
    for ch in text:
        glyph = GLYPHS[ch]
        gw = len(glyph[0])
        for row, line in enumerate(glyph):
            for col, c in enumerate(line):
                if c == "#":
                    d.rectangle(
                        [x + col * px, y0 + row * px,
                         x + col * px + px - 1, y0 + row * px + px - 1],
                        fill=fill)
        x += (gw + spacing) * px
    return x - x0, 7 * px
