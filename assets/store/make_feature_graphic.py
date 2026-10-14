#!/usr/bin/env python3
"""Make the Google Play / F-Droid feature graphic.

Writes fastlane/metadata/android/<locale>/images/featureGraphic.png:
1024 x 500, 24-bit PNG (no alpha), as Google Play requires. The design is a
light Material 3 surface tinted with the app's indigo seed colour (#3F51B5),
two soft shapes in the icon's indigo and teal, the launcher icon
(assets/branding/icon-512.png) on the left and the store title plus a short
tagline on the right. Play may crop the edges and overlay a play button in
the middle on some surfaces, so all content stays well inside the frame.

Usage (from the repository root, needs Pillow):

    python3 assets/store/make_feature_graphic.py            # en-US only
    python3 assets/store/make_feature_graphic.py --all      # every locale in TAGLINES

The text uses Inter (the app's look) when installed and falls back to DejaVu
Sans or Liberation Sans; with the same fonts the output is byte-identical.
Locales without their own graphic use the en-US one in both stores.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "assets" / "branding" / "icon-512.png"
META = ROOT / "fastlane" / "metadata" / "android"

WIDTH, HEIGHT = 1024, 500
SCALE = 2  # draw at 2x and downsample for smooth edges

# Material 3 tones derived from the seed colour #3F51B5 and the icon.
BACKGROUND = (246, 245, 252)  # surface, tinted towards indigo
INDIGO = (63, 81, 181)  # seed / icon top-left
TEAL = (0, 150, 136)  # icon bottom-right
ON_SURFACE = (27, 27, 33)
ON_SURFACE_VARIANT = (70, 70, 84)

TITLE = "Mozhi Translate"
# Short, in the listing's own words (see short_description.txt). Keep each
# line under ~28 characters so it fits at this size.
TAGLINES = {
    "en-US": ("Private translation with", "Mozhi, DeepL and AI models"),
}

FONT_DIRS = (
    Path("/usr/share/fonts/opentype/inter"),
    Path("/usr/share/fonts/truetype/inter"),
    Path("/usr/share/fonts/truetype/dejavu"),
    Path("/usr/share/fonts/truetype/liberation"),
    Path("/Library/Fonts"),
    Path("C:/Windows/Fonts"),
)
BOLD_FONTS = ("Inter-Bold.otf", "Inter-Bold.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf")
REGULAR_FONTS = ("Inter-Medium.otf", "Inter-Regular.otf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf")


def font(names: tuple[str, ...], size: int) -> ImageFont.FreeTypeFont:
    for name in names:
        for folder in FONT_DIRS:
            path = folder / name
            if path.exists():
                return ImageFont.truetype(str(path), size)
    sys.exit(f"none of the fonts {names} found; install Inter or DejaVu Sans")


def render(tagline: tuple[str, ...]) -> Image.Image:
    s = SCALE
    w, h = WIDTH * s, HEIGHT * s
    canvas = Image.new("RGB", (w, h), BACKGROUND)

    # Two large, blurred, low-contrast circles in the icon's colours.
    shapes = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(shapes)
    draw.ellipse((-260 * s, -330 * s, 430 * s, 360 * s), fill=(*INDIGO, 40))
    draw.ellipse((700 * s, 250 * s, 1250 * s, 800 * s), fill=(*TEAL, 38))
    draw.ellipse((860 * s, -140 * s, 1120 * s, 120 * s), fill=(*INDIGO, 22))
    shapes = shapes.filter(ImageFilter.GaussianBlur(6 * s))
    canvas.paste(shapes, (0, 0), shapes)

    # Icon with a soft shadow, vertically centred on the left.
    size = 240 * s
    with Image.open(ICON) as raw:
        icon = raw.convert("RGBA").resize((size, size), Image.LANCZOS)
    x, y = 88 * s, (h - size) // 2
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    alpha = icon.getchannel("A").point(lambda a: a * 70 // 255)
    shadow.paste((20, 24, 60, 255), (x, y + 10 * s), alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * s))
    canvas.paste(shadow, (0, 0), shadow)
    canvas.paste(icon, (x, y), icon)

    # Title and tagline, left-aligned next to the icon.
    draw = ImageDraw.Draw(canvas)
    title_font = font(BOLD_FONTS, 68 * s)
    tag_font = font(REGULAR_FONTS, 34 * s)
    text_x = x + size + 52 * s
    line_gap = 10 * s
    title_box = draw.textbbox((0, 0), TITLE, font=title_font)
    tag_boxes = [draw.textbbox((0, 0), line, font=tag_font) for line in tagline]
    title_h = title_box[3] - title_box[1]
    tag_h = tag_font.size + line_gap
    accent_gap, accent_h = 26 * s, 6 * s
    block = title_h + accent_gap + accent_h + accent_gap + tag_h * len(tagline) - line_gap
    top = (h - block) // 2
    draw.text((text_x, top - title_box[1]), TITLE, font=title_font, fill=ON_SURFACE)
    accent_y = top + title_h + accent_gap
    for i, colour in enumerate((INDIGO, TEAL)):
        ax = text_x + i * 56 * s
        draw.rounded_rectangle(
            (ax, accent_y, ax + 48 * s, accent_y + accent_h), radius=accent_h // 2, fill=colour
        )
    ty = accent_y + accent_h + accent_gap
    for line, box in zip(tagline, tag_boxes):
        draw.text((text_x, ty - box[1] + (tag_font.size - (box[3] - box[1])) // 2),
                  line, font=tag_font, fill=ON_SURFACE_VARIANT)
        ty += tag_h
    right = max([title_box[2]] + [b[2] for b in tag_boxes]) + text_x
    if right > w - 48 * s:
        sys.exit(f"text too wide for {tagline!r}; shorten the tagline")

    return canvas.resize((WIDTH, HEIGHT), Image.LANCZOS)


def main() -> int:
    locales = TAGLINES if "--all" in sys.argv else {"en-US": TAGLINES["en-US"]}
    for locale, tagline in locales.items():
        dest = META / locale / "images" / "featureGraphic.png"
        dest.parent.mkdir(parents=True, exist_ok=True)
        render(tagline).save(dest, optimize=True)
        print(f"{dest.relative_to(ROOT)}  {WIDTH}x{HEIGHT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
