#!/usr/bin/env python3
"""Check `namedColors` in LeanSvg/Svg.lean against Pillow's CSS colour map.

Pillow's `PIL.ImageColor.colormap` is the CSS Color Level 4 extended colour
keyword table (147 names plus `rebeccapurple`, no `transparent`).  This
extracts the `(name, 0xRRGGBB)` pairs straight out of the Lean source with a
regex and asserts:

  * every Pillow name is present in the Lean list, with the same RGB value;
  * `transparent` is NOT in the Lean list (it is a special case in
    `parsePaint`, not an RGB colour name);
  * reports any Lean names Pillow doesn't know about ("extras"), as
    information rather than a failure -- Pillow's map is the lower bound.

Exits 0 and prints "OK" on success, otherwise prints the mismatches and
exits 1.
"""

import re
import sys
from pathlib import Path

from PIL import ImageColor

REPO = Path(__file__).resolve().parent.parent
SVG_LEAN = REPO / "LeanSvg" / "Svg.lean"

PAIR_RE = re.compile(r'\("([a-zA-Z]+)",\s*0x([0-9a-fA-F]{6})\)')


def extract_named_colors(text):
    """Pull the body of `def namedColors : List (String × Nat) := [...]` and
    regex out every `("name", 0xRRGGBB)` pair inside it."""
    m = re.search(
        r"def namedColors[^:]*:\s*List \(String × Nat\)\s*:=\s*\[(.*?)\]\n",
        text,
        re.DOTALL,
    )
    if not m:
        sys.exit("could not find `def namedColors : List (String × Nat) := [...]` in Svg.lean")
    body = m.group(1)
    pairs = PAIR_RE.findall(body)
    if not pairs:
        sys.exit("found namedColors but no (\"name\", 0xRRGGBB) pairs inside it")
    return {name.lower(): int(hexval, 16) for name, hexval in pairs}


def pillow_named_colors():
    out = {}
    for name, value in ImageColor.colormap.items():
        r, g, b = ImageColor.getrgb(value)
        out[name.lower()] = (r << 16) | (g << 8) | b
    return out


def main():
    lean_colors = extract_named_colors(SVG_LEAN.read_text())
    pillow_colors = pillow_named_colors()

    errors = []

    missing = sorted(set(pillow_colors) - set(lean_colors))
    if missing:
        errors.append("missing from Lean namedColors (%d): %s" % (len(missing), ", ".join(missing)))

    mismatched = sorted(
        name
        for name in set(pillow_colors) & set(lean_colors)
        if pillow_colors[name] != lean_colors[name]
    )
    if mismatched:
        for name in mismatched:
            errors.append(
                "value mismatch for %r: Lean 0x%06x, Pillow 0x%06x"
                % (name, lean_colors[name], pillow_colors[name])
            )

    if "transparent" in lean_colors:
        errors.append("`transparent` must not be in namedColors (it is a special case in parsePaint)")

    if errors:
        print("FAIL")
        for e in errors:
            print("  - %s" % e)
        sys.exit(1)

    extras = sorted(set(lean_colors) - set(pillow_colors))
    print("OK: %d/%d Pillow names present with matching values" % (len(pillow_colors), len(lean_colors)))
    if extras:
        print("extras in Lean not in Pillow's map (%d): %s" % (len(extras), ", ".join(extras)))


if __name__ == "__main__":
    main()
