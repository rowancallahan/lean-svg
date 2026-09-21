#!/usr/bin/env python3
"""Oracle check for MicroSvg/Font.lean (T25).

Compares `fontdump`'s output against fontTools, character by character, for:
glyph id (`getBestCmap`), advance (`hmtx`), raw quadratic contours
(`glyph.getCoordinates(glyfTable)`: points and `flags & 1` on-curve, grouped
by `endPtsOfContours`), and pair kerning to the next character (from the
legacy `kern` table if present, else `GPOS` pair positioning under a `kern`
feature, computed here by walking fontTools' own decompiled GPOS tables --
independently of, not by re-running, MicroSvg/Font.lean's `Font.kern`).
Exact integer equality throughout; any difference is reported as a mismatch.

    python3 tests/check_font.py <font.ttf> [text] [--all]
    python3 tests/check_font.py <subset.ttf> [text] --via-embedded NAME

The second form runs `fontdump --embedded NAME <text>` (the constant baked
into the binary) but still opens <subset.ttf> with fontTools as the oracle,
which checks that `MicroSvg.Fonts.NAME.bytes` really is byte-identical to
what pyftsubset produced (any difference in the *parse* of the same bytes
would show up as a normal mismatch above; a difference in the *bytes
themselves* would tend to show up as wholesale wrong glyph ids/contours).

--all replaces the given/default text with one character per codepoint in
the font's own cmap, sorted -- i.e. every glyph in the subset reachable from
a Unicode codepoint (not `.notdef`, which nothing maps to and which
`fontdump`'s character-driven interface has no way to name directly; noted
as a small, deliberate gap in the T25 Report).
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from fontTools.misc.roundTools import otRound
from fontTools.ttLib import TTFont

REPO = Path(__file__).resolve().parent.parent
FONTDUMP = REPO / ".lake" / "build" / "bin" / "fontdump"

# ASCII printable (U+0020-007E) plus a handful of Latin-1/Latin Extended-A/
# General Punctuation/Currency Symbols characters, as the T25 spec asks.
DEFAULT_TEXT = "".join(chr(c) for c in range(0x20, 0x7F)) + "éàüß€“”—"

TIMEOUT_S = 30


def run_fontdump(fontdump_args):
    proc = subprocess.run(
        [str(FONTDUMP)] + fontdump_args, capture_output=True, text=True, timeout=TIMEOUT_S
    )
    if proc.returncode != 0:
        sys.exit(f"fontdump failed (rc={proc.returncode}): {proc.stderr.strip()}")
    return json.loads(proc.stdout)


# --------------------------------------------------------------------------
# oracle: raw contours
# --------------------------------------------------------------------------


def raw_contours_oracle(font, glyph_name):
    glyf = font["glyf"]
    if glyph_name not in glyf.keys():
        return []
    g = glyf[glyph_name]
    if g.numberOfContours == 0:
        return []
    # `getCoordinates(round=otRound)` rounds a *simple* component's own
    # coordinates before its immediate parent's transform is applied, but
    # (by design, per its docstring) does NOT re-round a nested *composite*
    # component's already-transformed coordinates before a grandparent's
    # transform on top of them -- it defers that "to the end" to avoid
    # compounding rounding error, which means the coordinates this call
    # returns can still carry float residue for a composite-of-composite
    # glyph. `otRound` them ourselves at the end; plain `int()` (truncation)
    # was a bug in this oracle (not in the Lean parser): it silently floors
    # values like 838.9999999996 instead of rounding them to 839.
    coords, endPts, flags = g.getCoordinates(glyf, round=otRound)
    out = []
    start = 0
    for e in endPts:
        contour = [
            (otRound(coords[i][0]), otRound(coords[i][1]), bool(flags[i] & 1))
            for i in range(start, e + 1)
        ]
        out.append(contour)
        start = e + 1
    return out


# --------------------------------------------------------------------------
# oracle: kerning (legacy 'kern' table, else GPOS pair adjustment under
# a 'kern' feature -- reimplemented directly against fontTools' decompiled
# tables, independently of MicroSvg/Font.lean's own GPOS walk)
# --------------------------------------------------------------------------


def value1_xadvance(v1):
    return v1.XAdvance if v1 is not None and hasattr(v1, "XAdvance") else 0


def gpos_kern_lookup(font):
    if "GPOS" not in font:
        return None
    gpos = font["GPOS"].table
    lookup_indices = []
    for feat in gpos.FeatureList.FeatureRecord:
        if feat.FeatureTag == "kern":
            for li in feat.Feature.LookupListIndex:
                if li not in lookup_indices:
                    lookup_indices.append(li)
    subtables = []
    for li in lookup_indices:
        lookup = gpos.LookupList.Lookup[li]
        if lookup.LookupType == 2:
            subtables.extend(lookup.SubTable)
    if not subtables:
        return None

    def lookup(g1, g2):
        for st in subtables:
            if st.Format == 1:
                glyphs = st.Coverage.glyphs
                if g1 not in glyphs:
                    continue
                idx = glyphs.index(g1)
                for rec in st.PairSet[idx].PairValueRecord:
                    if rec.SecondGlyph == g2:
                        return value1_xadvance(rec.Value1)
            elif st.Format == 2:
                if g1 not in st.Coverage.glyphs:
                    continue
                c1 = st.ClassDef1.classDefs.get(g1, 0)
                c2 = st.ClassDef2.classDefs.get(g2, 0)
                if c1 >= len(st.Class1Record):
                    continue
                row = st.Class1Record[c1]
                if c2 >= len(row.Class2Record):
                    continue
                return value1_xadvance(row.Class2Record[c2].Value1)
        return 0

    return lookup


def kern_oracle(font):
    """Returns (lookup(g1, g2) -> int, source) where source is "kern",
    "GPOS", or "none" (no kerning info at all -> expect 0 always)."""
    if "kern" in font:
        pairs = {}
        found = False
        for st in font["kern"].kernTables:
            if getattr(st, "format", None) == 0 and (getattr(st, "coverage", 0) & 0x1):
                pairs.update(st.kernTable)
                found = True
        if found:
            return (lambda g1, g2: pairs.get((g1, g2), 0)), "kern"
    gp = gpos_kern_lookup(font)
    if gp is not None:
        return gp, "GPOS"
    return (lambda g1, g2: 0), "none"


# --------------------------------------------------------------------------
# comparison
# --------------------------------------------------------------------------


def expected_gid(order, cmap, cp):
    name = cmap.get(cp)
    return order.index(name) if name is not None else 0


def compare(font, dump):
    order = font.getGlyphOrder()
    cmap = font.getBestCmap()
    hmtx = font["hmtx"]
    kern_fn, kern_source = kern_oracle(font)

    glyphs_compared = 0
    mismatches = 0
    for i, entry in enumerate(dump):
        cp = entry["codepoint"]
        gid = expected_gid(order, cmap, cp)
        name = order[gid]
        glyphs_compared += 1
        ok = True

        if entry["glyphId"] != gid:
            ok = False
            print(f"  MISMATCH glyphId char={entry['char']!r} cp={cp:#x}: got {entry['glyphId']} want {gid}")

        want_adv = hmtx[name][0] if name in hmtx.metrics else 0
        if entry["advance"] != want_adv:
            ok = False
            print(f"  MISMATCH advance char={entry['char']!r}: got {entry['advance']} want {want_adv}")

        want_contours = raw_contours_oracle(font, name)
        got_contours = [[(p[0], p[1], bool(p[2])) for p in c] for c in entry["contours"]]
        if got_contours != want_contours:
            ok = False
            print(
                f"  MISMATCH contours char={entry['char']!r} gid={gid}: "
                f"got {len(got_contours)} contours, want {len(want_contours)}"
            )
            for gc, wc in zip(got_contours, want_contours):
                if gc != wc:
                    print(f"    got  {gc}")
                    print(f"    want {wc}")
                    break

        if i + 1 < len(dump):
            next_cp = dump[i + 1]["codepoint"]
            gid2 = expected_gid(order, cmap, next_cp)
            want_kern = kern_fn(name, order[gid2])
            if entry["kernToNext"] != want_kern:
                ok = False
                print(
                    f"  MISMATCH kern {entry['char']!r}->{dump[i + 1]['char']!r}: "
                    f"got {entry['kernToNext']} want {want_kern}"
                )

        if not ok:
            mismatches += 1

    return glyphs_compared, mismatches, kern_source


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ttf", type=Path)
    ap.add_argument("text", nargs="?", default=None)
    ap.add_argument("--all", action="store_true", help="use every codepoint in the font's own cmap")
    ap.add_argument("--via-embedded", default=None, metavar="NAME")
    args = ap.parse_args()

    font = TTFont(str(args.ttf))
    if args.all:
        cmap = font.getBestCmap()
        # Exclude C0/C1 control codepoints (notably U+0000, which cannot survive
        # as a null byte in a subprocess argv) -- fonts sometimes map these to
        # a "not a character" glyph, but they carry no shape worth oracle-testing.
        codepoints = [cp for cp in sorted(cmap.keys()) if not (cp < 0x20 or 0x7F <= cp < 0xA0)]
        text = "".join(chr(cp) for cp in codepoints)
    else:
        text = args.text if args.text is not None else DEFAULT_TEXT

    if args.via_embedded:
        dump = run_fontdump(["--embedded", args.via_embedded, text])
    else:
        dump = run_fontdump([str(args.ttf), text])

    glyphs_compared, mismatches, kern_source = compare(font, dump)
    label = f"{args.ttf.name} (via --embedded {args.via_embedded})" if args.via_embedded else args.ttf.name
    print(f"{label}: {glyphs_compared} glyphs compared, {mismatches} mismatches (kerning oracle: {kern_source})")
    sys.exit(1 if mismatches else 0)


if __name__ == "__main__":
    main()
