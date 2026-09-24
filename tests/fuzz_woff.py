#!/usr/bin/env python3
"""Totality fuzzer for LeanSvg/Brotli.lean and LeanSvg/Woff.lean (T105).

Like tests/fuzz_font.py, but for the font *containers*: a WOFF 2.0 (or WOFF
1.0) file is mutated and fed to `fontdump` (which decodes it with
`Woff.parseFont` and then reads glyphs), checking that every run exits 0 or
1 within the timeout, is never killed by a signal and prints no panic /
stack-overflow marker.  Mutators:

- byte flips anywhere, and inside the Brotli stream only;
- truncation;
- huge or inconsistent header sizes (`totalSfntSize`, `totalCompressedSize`)
  and directory lengths (`origLength`/`transformLength` as 5-byte
  UIntBase128 up to 2^32 - 1);
- decompress, corrupt the *transformed* `glyf` stream (stream sizes, contour
  counts, point counts, flags, triplets, composite flags, bbox bitmap) or
  `hmtx` flags, then recompress, so the corruption reaches
  `Woff.reconstructGlyf`/`reconstructHmtx` instead of dying in Brotli;
- raw Brotli: random or mutated streams through `fontdump --brotli` with a
  random expected size.

    python3 tests/fuzz_woff.py font.woff2 --iters 2000 --seed 1
"""

import argparse
import random
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import brotli

REPO = Path(__file__).resolve().parent.parent
FONTDUMP = REPO / ".lake" / "build" / "bin" / "fontdump"
TIMEOUT_S = 20
PROBE_TEXT = "ABCXYZabcxyz012 .,;:!?"
CRASH_MARKERS = ["PANIC", "panic", "Stack overflow", "INTERNAL ERROR", "internal error",
                 "uncaught exception", "Segmentation", "Assertion", "assert"]


def base128(v):
    out = [v & 0x7F]
    v >>= 7
    while v:
        out.append(0x80 | (v & 0x7F))
        v >>= 7
    return bytes(reversed(out))


def read_base128(b, i):
    acc = 0
    for k in range(5):
        c = b[i + k]
        acc = (acc << 7) | (c & 0x7F)
        if c < 128:
            return acc, i + k + 1
    raise ValueError("bad base128")


def parse_woff2(b):
    """(directory entries [(start, end, tag_index, transformed, length)], stream offset)."""
    num = struct.unpack_from(">H", b, 12)[0]
    p = 48
    entries = []
    for _ in range(num):
        s = p
        fl = b[p]
        p += 1
        if fl & 63 == 63:
            p += 4
        orig, p = read_base128(b, p)
        idx = fl & 63
        tv = fl >> 6
        transformed = (tv == 0) if idx in (10, 11) else (tv != 0)
        length = orig
        if transformed:
            length, p = read_base128(b, p)
        entries.append((s, p, idx, transformed, length))
    return entries, p


def mutate_flips(data, rng):
    b = bytearray(data)
    for _ in range(rng.randint(1, 16)):
        b[rng.randrange(len(b))] = rng.randrange(256)
    return bytes(b)


def mutate_stream_flips(data, rng):
    b = bytearray(data)
    _, start = parse_woff2(data)
    for _ in range(rng.randint(1, 8)):
        b[rng.randrange(start, len(b))] ^= 1 << rng.randrange(8)
    return bytes(b)


def mutate_truncate(data, rng):
    return data[: rng.randrange(len(data))]


def mutate_header_sizes(data, rng):
    b = bytearray(data)
    off = rng.choice([8, 16, 20])
    struct.pack_into(">I", b, off, rng.choice([0, 1, 0xFFFFFFFF, 1 << 24, 16 * 1024 * 1024 + 1, rng.randrange(1 << 32)]))
    return bytes(b)


def mutate_dir_length(data, rng):
    entries, _ = parse_woff2(data)
    s, e, idx, tr, _ = rng.choice(entries)
    head = data[s:e]
    fl = head[0]
    tagb = head[1:5] if fl & 63 == 63 else b""
    v = rng.choice([0, 1, 0xFFFFFFFF, 1 << 24, 16 * 1024 * 1024 + 1, rng.randrange(1 << 20)])
    new = bytes([fl]) + tagb + base128(v)
    if tr:
        new += base128(rng.choice([v, 0, rng.randrange(1 << 16)]))
    return data[:s] + new + data[e:]


def recompress_with(data, rng, edit):
    entries, start = parse_woff2(data)
    comp = struct.unpack_from(">I", data, 20)[0]
    raw = bytearray(brotli.decompress(data[start:start + comp]))
    offs = {}
    q = 0
    for (_, _, idx, tr, length) in entries:
        offs[idx] = (q, length, tr)
        q += length
    edit(raw, offs, rng)
    c = brotli.compress(bytes(raw), quality=rng.choice([0, 5, 11]))
    b = bytearray(data[:start]) + c
    struct.pack_into(">I", b, 20, len(c))
    struct.pack_into(">I", b, 8, len(b))
    return bytes(b)


def edit_glyf(raw, offs, rng):
    if 10 not in offs or not offs[10][2]:
        return
    g, length, _ = offs[10]
    kind = rng.randrange(4)
    if kind == 0:   # one of the header's stream sizes / counts
        field = rng.choice([2, 4, 6] + [8 + 4 * k for k in range(7)])
        if field < 8:
            struct.pack_into(">H", raw, g + field, rng.choice([0, 1, 0xFFFF, rng.randrange(65536)]))
        else:
            struct.pack_into(">I", raw, g + field, rng.choice([0, 1, 0xFFFFFFFF, rng.randrange(1 << 16)]))
    elif kind == 1:  # contour counts: -1 (composite), -2, huge
        n = struct.unpack_from(">H", raw, g + 4)[0]
        if n:
            k = rng.randrange(n)
            struct.pack_into(">h", raw, g + 36 + 2 * k, rng.choice([-1, -2, 32767, 1, 0]))
    else:            # anywhere in the streams
        for _ in range(rng.randint(1, 8)):
            i = g + 36 + rng.randrange(max(1, length - 36))
            if i < len(raw):
                raw[i] = rng.randrange(256)


def edit_hmtx(raw, offs, rng):
    if 3 not in offs:
        return
    h, length, _ = offs[3]
    for _ in range(rng.randint(1, 4)):
        raw[h + rng.randrange(max(1, length))] = rng.randrange(256)


def mutate_glyf_transform(data, rng):
    return recompress_with(data, rng, edit_glyf)


def mutate_hmtx_transform(data, rng):
    return recompress_with(data, rng, edit_hmtx)


WOFF2_MUTATORS = [mutate_flips, mutate_stream_flips, mutate_truncate, mutate_header_sizes,
                  mutate_dir_length, mutate_glyf_transform, mutate_hmtx_transform]
WOFF1_MUTATORS = [mutate_flips, mutate_truncate]


def run(cmd):
    """(violation or None, exit code)."""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return "timeout", None
    if p.returncode not in (0, 1):
        return f"exit code {p.returncode}", p.returncode
    err = p.stderr.decode("utf-8", "replace")
    for m in CRASH_MARKERS:
        if m in err:
            return f"stderr marker {m!r}", p.returncode
    return None, p.returncode


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("font", type=Path)
    ap.add_argument("--iters", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    assert FONTDUMP.exists(), f"fontdump not found at {FONTDUMP}; run `lake build`"
    data = args.font.read_bytes()
    is2 = data[:4] == b"wOF2"
    mutators = WOFF2_MUTATORS if is2 else WOFF1_MUTATORS
    rng = random.Random(args.seed)
    counts, violations = {}, []
    start = time.time()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / "m.bin"
        for i in range(args.iters):
            if is2 and rng.random() < 0.15:
                # raw Brotli
                name = "raw_brotli"
                if rng.random() < 0.5:
                    blob = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 64)))
                else:
                    src = bytes(rng.choice(b"abc \x00\xff") for _ in range(rng.randrange(1, 4000)))
                    blob = mutate_flips(brotli.compress(src, quality=rng.choice([1, 11])), rng)
                tmp.write_bytes(blob)
                cmd = [str(FONTDUMP), "--brotli", str(tmp), str(rng.choice([0, 1, 100, 4000, 1 << 24]))]
            else:
                m = rng.choice(mutators)
                name = m.__name__
                try:
                    blob = m(data, rng)
                except Exception:
                    blob = mutate_flips(data, rng)
                tmp.write_bytes(blob)
                cmd = [str(FONTDUMP), str(tmp), PROBE_TEXT]
            v, rc = run(cmd)
            ok, rej = counts.get(name, (0, 0))
            counts[name] = (ok + (rc == 0), rej + (rc == 1))
            if v:
                violations.append((i, name, v))
    el = time.time() - start
    print(f"{args.iters} iterations in {el:.1f}s, seed={args.seed}")
    for k, (ok, rej) in sorted(counts.items()):
        print(f"  {k}: {ok + rej} ({ok} decoded, {rej} rejected)")
    print(f"{len(violations)} violations")
    for v in violations[:50]:
        print("  VIOLATION", v)
    sys.exit(1 if violations else 0)


if __name__ == "__main__":
    main()
