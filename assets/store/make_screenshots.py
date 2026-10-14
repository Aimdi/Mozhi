#!/usr/bin/env python3
"""Make the store screenshots from assets/screenshots.

The app screenshots are 412 x 915 (about 1 : 2.22). Google Play rejects
screenshots whose long side is more than twice the short side, so each copy
is widened to the smallest width that fits 2:1 (458 x 915 here). The extra
columns repeat each row's edge pixel, so the app bar, the background and the
navigation bar simply continue to the new edge; nothing is cropped or scaled.
The result is a 24-bit PNG (no alpha), which F-Droid accepts as well.

Usage (from the repository root, needs Pillow):

    python3 assets/store/make_screenshots.py

It overwrites fastlane/metadata/android/en-US/images/phoneScreenshots/ with
the files listed in SHOTS (Play allows at most 8 per device type). The output
is deterministic: the same inputs give byte-identical PNGs.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets" / "screenshots"
OUT = ROOT / "fastlane" / "metadata" / "android" / "en-US" / "images" / "phoneScreenshots"

# Store order: AI translation, alignment, refine, compare engines, word
# insights, check meaning, proofread, dark mode.
SHOTS = (
    "translate-ai",
    "alignment",
    "refine",
    "compare-engines",
    "word-insights",
    "meaning-check",
    "proofread",
    "dark-mode",
)
MAX_RATIO = 2  # Google Play: long side <= 2 x short side.


def fit_ratio(image: Image.Image) -> Image.Image:
    """Return [image] as RGB, padded with its edge pixels to at most 2:1."""
    image = image.convert("RGB")
    w, h = image.size
    if h > MAX_RATIO * w:  # portrait: widen
        new_w, new_h = math.ceil(h / MAX_RATIO), h
    elif w > MAX_RATIO * h:  # landscape: heighten
        new_w, new_h = w, math.ceil(w / MAX_RATIO)
    else:
        return image
    out = Image.new("RGB", (new_w, new_h))
    left, top = (new_w - w) // 2, (new_h - h) // 2
    out.paste(image, (left, top))
    if new_w > w:
        right = new_w - w - left
        first = image.crop((0, 0, 1, h))
        last = image.crop((w - 1, 0, w, h))
        if left:
            out.paste(first.resize((left, h), Image.NEAREST), (0, 0))
        if right:
            out.paste(last.resize((right, h), Image.NEAREST), (left + w, 0))
    if new_h > h:
        bottom = new_h - h - top
        first = image.crop((0, 0, w, 1))
        last = image.crop((0, h - 1, w, h))
        if top:
            out.paste(first.resize((w, top), Image.NEAREST), (0, 0))
        if bottom:
            out.paste(last.resize((w, bottom), Image.NEAREST), (0, top + h))
    return out


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    for index, name in enumerate(SHOTS, start=1):
        src = SRC / f"{name}.png"
        if not src.exists():
            print(f"missing {src.relative_to(ROOT)}", file=sys.stderr)
            return 1
        with Image.open(src) as image:
            result = fit_ratio(image)
        dest = OUT / f"{index:02d}-{name}.png"
        result.save(dest, optimize=True)
        print(f"{dest.relative_to(ROOT)}  {result.size[0]}x{result.size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
