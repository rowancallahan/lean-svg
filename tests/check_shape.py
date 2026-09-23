#!/usr/bin/env python3
"""Differential test of LeanSvg.Shape (T93) against HarfBuzz (uharfbuzz).

Every case is one run of codepoints, shaped with one of the embedded fonts
(the exact bytes of LeanSvg/Fonts/<Module>.lean, decoded from its base64
chunks) in one direction, by `.lake/build/bin/shapedump` and by uharfbuzz
(`add_codepoints`, so clusters are codepoint indices; `guess_segment_properties`
then the direction, as usvg does with harfrust).  Glyph ids, clusters,
advances and offsets must all agree.

    python3 tests/check_shape.py [N_RANDOM] [SEED]

Cases: hand-written words and sentences per script (Arabic with harakat and
lam-alef, Hebrew with niqqud, Devanagari conjuncts, reph, pre-base matras,
nukta, broken clusters), then random strings drawn per script from a pool of
its letters, marks, joiners, digits and punctuation.
"""

import base64
import random
import re
import subprocess
import sys
from pathlib import Path

import uharfbuzz as hb

REPO = Path(__file__).resolve().parent.parent
DUMP = REPO / ".lake" / "build" / "bin" / "shapedump"


def font_bytes(module: str) -> bytes:
    src = (REPO / "LeanSvg" / "Fonts" / f"{module}.lean").read_text()
    chunks = re.findall(r'^  "([A-Za-z0-9+/=]*)",$', src, re.M)
    return base64.b64decode("".join(chunks))


FONTS = {}


def hb_script(cp: int) -> str:
    buf = hb.Buffer()
    buf.add_codepoints([cp])
    buf.guess_segment_properties()
    return buf.script or "Zyyy"


def hb_shape(module: str, cps: list[int], rtl: bool, kern: bool) -> list[list[int]]:
    if module not in FONTS:
        FONTS[module] = hb.Font(hb.Face(hb.Blob(font_bytes(module))))
    font = FONTS[module]
    buf = hb.Buffer()
    buf.add_codepoints(cps)
    buf.guess_segment_properties()
    buf.direction = "rtl" if rtl else "ltr"
    buf.language = "und"
    feats = {} if kern else {"kern": False}
    hb.shape(font, buf, feats)
    return [[i.codepoint, i.cluster, p.x_advance, p.x_offset, p.y_offset]
            for i, p in zip(buf.glyph_infos, buf.glyph_positions)]


ARABIC = [
    "اقرأ المزيد عن SVG أيضًا.", "مرحبا العالم!", "لا بسم الله الرحمن الرحيم", "ناتساد",
    "هالو", "مَرْحَبًا", "لأ لإ لآ", "بِسْمِ ٱللَّهِ", "ـبـ", "كتب", "في ١٢٣ سنة", "(مرحبا)",
    "شَدَّة", "ﻻ", "الحمد لله", "تجربة الخط العربي", "a ب c",
]
HEBREW = ["שָׁלוֹם עוֹלָם", "בְּרֵאשִׁית", "עברית", "שלום (עולם)", "ספר 123", "וַיֹּאמֶר", "תּוֹרָה"]
DEVANAGARI = [
    "नमस्ते दुनिया", "किसी", "र्क क्ष त्र श्र हिन्दी", "क", "हिंदी", "स्त्री", "कर्म", "धर्म",
    "प्रेम", "द्वार", "क़", "ज़्यादा", "ि", "्", "अॆ", "र्", "कि्", "क्‍ष", "क्‌ष", "पृथ्वी", "राष्ट्र",
    "र्कि", "ॐ", "१२३", "ह्म", "ङ्क", "त्त", "द्ध",
]
POOLS = {
    "Amiri": [chr(c) for c in list(range(0x621, 0x64B)) + list(range(0x64B, 0x656)) + [0x670, 0x671, 0x6CC,
              0x6A9, 0x6AF, 0x640, 0x660, 0x661, 0x200C, 0x200D, 0x20, 0x20, 0x2E, 0x28, 0x29, 0x21]],
    "NotoSansHebrew": [chr(c) for c in list(range(0x5D0, 0x5EB)) + list(range(0x5B0, 0x5BE)) + [0x5C1, 0x5C2,
              0x5BF, 0x20, 0x20, 0x2E, 0x28, 0x29, 0x31, 0x32]],
    "NotoSansDevanagari": [chr(c) for c in list(range(0x905, 0x915)) + list(range(0x915, 0x93A)) * 2 +
              list(range(0x93C, 0x94E)) + [0x94D] * 12 + [0x930] * 6 + [0x902, 0x901, 0x903, 0x200C, 0x200D,
              0x20, 0x966, 0x967, 0x964, 0x93D, 0x950, 0x958, 0x959, 0x25CC]],
}


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rng = random.Random(seed)
    cases = []
    for t in ARABIC:
        cases += [("Amiri", t, True, True), ("Amiri", t, False, True)]
    cases += [("Amiri", "final office", False, True), ("Amiri", "AVAWA fi", False, False)]
    for t in HEBREW:
        cases += [("NotoSansHebrew", t, True, True), ("NotoSansHebrew", t, False, True)]
    for t in DEVANAGARI:
        cases += [("NotoSansDevanagari", t, False, True)]
    for k in range(n):
        m = rng.choice(list(POOLS))
        t = "".join(rng.choice(POOLS[m]) for _ in range(rng.randint(1, 12)))
        cases.append((m, t, m != "NotoSansDevanagari" and rng.random() < 0.8, rng.random() < 0.9))
    lines = ["S %s %d %d %s" % (m, rtl, kern, " ".join("%x" % ord(c) for c in t)) for m, t, rtl, kern in cases]
    out = subprocess.run([str(DUMP)], input="\n".join(lines) + "\n", capture_output=True, text=True,
                         check=True).stdout.splitlines()
    assert len(out) == len(cases), (len(out), len(cases))
    bad = 0
    skipped = 0
    per = {}
    for (m, t, rtl, kern), got in zip(cases, out):
        # harfrust (resvg's shaper) gives a run with no script (only Common and
        # Inherited characters) no native direction; HarfBuzz C calls it LTR and
        # reverses an RTL run's graphemes.  Such runs are not comparable.
        if rtl and all(hb_script(ord(c)) in ("Zyyy", "Zinh", "Zzzz") for c in t):
            skipped += 1
            continue
        exp = hb_shape(m, [ord(c) for c in t], rtl, kern)
        ours = eval(got) if got.startswith("[") else got
        per.setdefault(m, [0, 0])[0] += 1
        if ours != exp:
            bad += 1
            per[m][1] += 1
            if bad <= 15:
                print(f"MISMATCH {m} rtl={rtl} kern={kern} {t!r} {[hex(ord(c)) for c in t]}")
                print("  hb  ", exp)
                print("  ours", ours)
    for m, (a, b) in per.items():
        print(f"{m}: {a - b}/{a} identical")
    print(f"total: {len(cases) - skipped - bad}/{len(cases) - skipped} identical "
          f"({skipped} script-less RTL runs skipped)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
