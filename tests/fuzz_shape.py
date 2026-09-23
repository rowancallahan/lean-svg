#!/usr/bin/env python3
"""Totality fuzzer for LeanSvg/Shape.lean and LeanSvg/ShapeRun.lean (T93).

Shaping reads GSUB, GPOS and GDEF straight out of the font's bytes, so a
corrupted table must never crash `shapedump`, make it loop, or blow up its
output: it may only shape differently.  This mutates one of the embedded
shaped fonts (the exact bytes of LeanSvg/Fonts/<Module>.lean) inside those
three tables -- byte flips, u16 fields set to 0 / 1 / 0xFFFF / random, a
nested lookup record pointed back at its own lookup (recursion), lookup
types and subtable counts scrambled, truncation -- and shapes a probe string
in the font's script with each mutant, under a timeout, checking the exit
code, stderr, and that the glyph count stays within the growth cap.

    python3 tests/fuzz_shape.py --font Amiri --iters 1000 --seed 1
"""

import argparse
import base64
import random
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DUMP = REPO / ".lake" / "build" / "bin" / "shapedump"
TIMEOUT_S = 20
PROBES = {
    "Amiri": ("1", "اقرأ المزيد عن SVG أيضًا لا بِسْمِ ٱللَّهِ final"),
    "NotoSansHebrew": ("1", "שָׁלוֹם עוֹלָם בְּרֵאשִׁית (123)"),
    "NotoSansDevanagari": ("0", "नमस्ते हिन्दी र्क क्ष त्र श्र ि् क़"),
}


def font_bytes(module):
    src = (REPO / "LeanSvg" / "Fonts" / f"{module}.lean").read_text()
    return base64.b64decode("".join(re.findall(r'^  "([A-Za-z0-9+/=]*)",$', src, re.M)))


def tables(b):
    n = struct.unpack_from(">H", b, 4)[0]
    out = {}
    for i in range(n):
        tag, _, off, ln = struct.unpack_from(">4sIII", b, 12 + 16 * i)
        out[tag.decode("latin1")] = (off, ln)
    return out


def mutate(data, rng):
    b = bytearray(data)
    t = tables(b)
    tag = rng.choice([k for k in ("GSUB", "GPOS", "GDEF") if k in t])
    off, ln = t[tag]
    kind = rng.randrange(6)
    if kind == 0:      # byte flips
        for _ in range(rng.randint(1, 20)):
            b[off + rng.randrange(ln)] ^= 1 << rng.randrange(8)
    elif kind == 1:    # u16 fields to extremes
        for _ in range(rng.randint(1, 8)):
            i = off + 2 * rng.randrange(ln // 2)
            struct.pack_into(">H", b, i, rng.choice([0, 1, 2, 0xFFFF, 0x7FFF, rng.randrange(65536)]))
    elif kind == 2 and tag != "GDEF":   # lookup type / subtable count scramble
        ll = off + struct.unpack_from(">H", b, off + 8)[0]
        n = struct.unpack_from(">H", b, ll)[0]
        for _ in range(rng.randint(1, 4)):
            lo = ll + struct.unpack_from(">H", b, ll + 2 + 2 * rng.randrange(max(n, 1)))[0]
            if lo + 6 <= len(b):
                if rng.random() < 0.5:
                    struct.pack_into(">H", b, lo, rng.randrange(1, 10))
                else:
                    struct.pack_into(">H", b, lo + 4, rng.choice([0, 1, 0xFFFF]))
    elif kind == 3 and tag != "GDEF":   # nested lookup records pointing at arbitrary lookups
        ll = off + struct.unpack_from(">H", b, off + 8)[0]
        n = struct.unpack_from(">H", b, ll)[0]
        for _ in range(rng.randint(1, 30)):
            i = off + 2 * rng.randrange(ln // 2)
            struct.pack_into(">H", b, i, rng.randrange(max(n, 1)))
    elif kind == 4:    # truncate inside the table
        b = b[: off + rng.randrange(ln)]
    else:              # zero a random span
        s = off + rng.randrange(ln)
        for i in range(s, min(len(b), s + rng.randint(1, 64))):
            b[i] = 0
    return bytes(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", default="Amiri", choices=list(PROBES))
    ap.add_argument("--iters", type=int, default=500)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    base = font_bytes(a.font)
    rtl, text = PROBES[a.font]
    cps = " ".join("%x" % ord(c) for c in text)
    cap = 16 * len(text) + 256
    bad = 0
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "m.ttf"
        for it in range(a.iters):
            path.write_bytes(mutate(base, rng))
            line = f"F {path} {rtl} 1 {cps}\n"
            try:
                p = subprocess.run([str(DUMP)], input=line, capture_output=True, text=True, timeout=TIMEOUT_S)
            except subprocess.TimeoutExpired:
                bad += 1
                print(f"iter {it}: TIMEOUT")
                (Path("/tmp") / f"fuzz_shape_timeout_{a.font}_{it}.ttf").write_bytes(path.read_bytes())
                continue
            out = p.stdout.strip()
            ok = p.returncode == 0 and not p.stderr.strip() and (
                out.startswith("error:") or (out.startswith("[") and out.count("[") - 1 <= cap))
            if not ok:
                bad += 1
                print(f"iter {it}: rc={p.returncode} stderr={p.stderr[:200]!r} out={out[:120]!r}")
    print(f"{a.font}: {a.iters} mutants, {bad} violations")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
