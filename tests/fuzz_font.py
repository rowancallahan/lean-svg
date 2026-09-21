#!/usr/bin/env python3
"""Totality fuzzer for MicroSvg/Font.lean (T25).

`Font.parse` and its accessors must be total: a random, truncated, or
adversarially corrupted byte string can never crash `fontdump` or make it
loop forever, only ever return `some`/`none` (exit 0) with well-formed JSON,
or a clean parse failure (exit 1). This mutates a real font in several
targeted ways -- plain byte flips, truncation, table-offset/length
corruption, `loca` scrambling, composite glyph cycles (a component pointing
at its own glyph id, to probe the fuel-bounded recursion), and a huge
`maxp.numGlyphs` -- and runs `fontdump` on each mutant with a timeout,
checking it never times out, is never killed by a signal, exits only 0 or 1,
and prints no panic/stack-overflow marker to stderr.

    python3 tests/fuzz_font.py <font.ttf> --iters 2000 --seed 1
"""

import argparse
import random
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FONTDUMP = REPO / ".lake" / "build" / "bin" / "fontdump"

TIMEOUT_S = 20
PROBE_TEXT = "ABCXYZabcxyz012 .,;:!?éàüß€"
CRASH_MARKERS = [
    "PANIC",
    "panic",
    "Stack overflow",
    "INTERNAL ERROR",
    "internal error",
    "uncaught exception",
    "Segmentation",
    "Assertion",
    "assert",
]


# --------------------------------------------------------------------------
# byte helpers
# --------------------------------------------------------------------------


def u16(b, i):
    return struct.unpack_from(">H", b, i)[0]


def u32(b, i):
    return struct.unpack_from(">I", b, i)[0]


def i16(b, i):
    return struct.unpack_from(">h", b, i)[0]


def set_u16(b, i, v):
    b[i : i + 2] = struct.pack(">H", v & 0xFFFF)


def set_u32(b, i, v):
    b[i : i + 4] = struct.pack(">I", v & 0xFFFFFFFF)


def table_dir(data):
    """{tag: (recordOffset, tableOffset, tableLength)} for a well-formed
    sfnt directory; {} if `data` is too short or malformed to have one (the
    mutators fall back to a plain byte flip in that case)."""
    if len(data) < 12:
        return {}
    try:
        numTables = u16(data, 4)
    except struct.error:
        return {}
    out = {}
    for i in range(numTables):
        rec = 12 + 16 * i
        if rec + 16 > len(data):
            break
        tag = bytes(data[rec : rec + 4]).decode("latin1")
        out[tag] = (rec, u32(data, rec + 8), u32(data, rec + 12))
    return out


# --------------------------------------------------------------------------
# mutation strategies -- each takes the original bytes and returns mutant bytes
# --------------------------------------------------------------------------


def mutate_byte_flips(data, rng):
    b = bytearray(data)
    if not b:
        return bytes(b)
    for _ in range(rng.randint(1, 20)):
        b[rng.randrange(len(b))] = rng.randrange(256)
    return bytes(b)


def mutate_truncate(data, rng):
    if len(data) < 2:
        return data
    return data[: rng.randrange(1, len(data))]


def mutate_table_offset(data, rng):
    b = bytearray(data)
    dirs = table_dir(b)
    if not dirs:
        return mutate_byte_flips(data, rng)
    rec, _, _ = rng.choice(list(dirs.values()))
    choice = rng.choice(["offset_huge", "offset_zero", "length_huge", "length_zero", "offset_past_end"])
    if choice == "offset_huge":
        set_u32(b, rec + 8, rng.randrange(0xF0000000, 0xFFFFFFFF))
    elif choice == "offset_zero":
        set_u32(b, rec + 8, 0)
    elif choice == "length_huge":
        set_u32(b, rec + 12, rng.randrange(0xF0000000, 0xFFFFFFFF))
    elif choice == "length_zero":
        set_u32(b, rec + 12, 0)
    else:
        set_u32(b, rec + 8, len(b) + rng.randrange(1, 1000))
    return bytes(b)


def head_maxp_info(b, dirs):
    """(indexToLocFormat, numGlyphs), or None if head/maxp are missing/too short."""
    if "head" not in dirs or "maxp" not in dirs:
        return None
    _, headOff, headLen = dirs["head"]
    _, maxpOff, maxpLen = dirs["maxp"]
    if headLen < 52 or maxpLen < 6 or headOff + 52 > len(b) or maxpOff + 6 > len(b):
        return None
    return i16(b, headOff + 50), u16(b, maxpOff + 4)


def mutate_loca_scramble(data, rng):
    b = bytearray(data)
    dirs = table_dir(b)
    if "loca" not in dirs:
        return mutate_byte_flips(data, rng)
    info = head_maxp_info(b, dirs)
    if info is None:
        return mutate_byte_flips(data, rng)
    indexToLocFormat, numGlyphs = info
    _, locaOff, locaLen = dirs["loca"]
    entrySize = 4 if indexToLocFormat == 1 else 2
    nEntries = numGlyphs + 1
    if locaLen < nEntries * entrySize or locaOff + locaLen > len(b):
        return mutate_byte_flips(data, rng)
    for _ in range(rng.randint(1, 10)):
        pos = locaOff + rng.randrange(nEntries) * entrySize
        if entrySize == 4:
            set_u32(b, pos, rng.randrange(0, 0xFFFFFFFF))
        else:
            set_u16(b, pos, rng.randrange(0, 0xFFFF))
    return bytes(b)


def mutate_composite_cycle(data, rng):
    """Point a composite glyph's first component at its own glyph id (or
    another composite's), which is exactly what the fuel-bounded recursion
    in `Font.resolvedContours` exists to survive."""
    b = bytearray(data)
    dirs = table_dir(b)
    if "loca" not in dirs or "glyf" not in dirs:
        return mutate_byte_flips(data, rng)
    info = head_maxp_info(b, dirs)
    if info is None:
        return mutate_byte_flips(data, rng)
    indexToLocFormat, numGlyphs = info
    _, locaOff, locaLen = dirs["loca"]
    _, glyfOff, glyfLen = dirs["glyf"]
    entrySize = 4 if indexToLocFormat == 1 else 2
    if locaLen < (numGlyphs + 1) * entrySize or locaOff + locaLen > len(b):
        return mutate_byte_flips(data, rng)

    def loca_entry(i):
        pos = locaOff + i * entrySize
        return u32(b, pos) if entrySize == 4 else 2 * u16(b, pos)

    candidates = []
    for gid in range(min(numGlyphs, 2000)):
        o0, o1 = loca_entry(gid), loca_entry(gid + 1)
        if o1 <= o0 or glyfOff + o0 + 14 > len(b):
            continue
        if i16(b, glyfOff + o0) < 0:
            candidates.append((gid, glyfOff + o0))
    if not candidates:
        return mutate_byte_flips(data, rng)
    gid, goff = rng.choice(candidates)
    set_u16(b, goff + 12, gid)  # first component's glyph index, right after flags(2)+gid(2) header
    return bytes(b)


def mutate_huge_numglyphs(data, rng):
    b = bytearray(data)
    dirs = table_dir(b)
    if "maxp" not in dirs:
        return mutate_byte_flips(data, rng)
    _, maxpOff, maxpLen = dirs["maxp"]
    if maxpLen < 6 or maxpOff + 6 > len(b):
        return mutate_byte_flips(data, rng)
    set_u16(b, maxpOff + 4, rng.choice([0xFFFF, 0x8000, 0x7FFF, 0xFFFE]))
    return bytes(b)


MUTATORS = [
    mutate_byte_flips,
    mutate_truncate,
    mutate_table_offset,
    mutate_loca_scramble,
    mutate_composite_cycle,
    mutate_huge_numglyphs,
]


# --------------------------------------------------------------------------
# running fontdump and judging the result
# --------------------------------------------------------------------------


def run_fontdump(path, text, timeout):
    try:
        proc = subprocess.run([str(FONTDUMP), str(path), text], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, b"", True
    return proc.returncode, proc.stderr, False


def violation(rc, stderr, timed_out):
    if timed_out:
        return "timeout"
    if rc is None or rc < 0:
        return f"killed by signal {-rc if rc else '?'}"
    if rc not in (0, 1):
        return f"unexpected exit code {rc}"
    text = stderr.decode("utf-8", "replace")
    for marker in CRASH_MARKERS:
        if marker in text:
            return f"crash marker {marker!r} in stderr"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("font", type=Path)
    ap.add_argument("--iters", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--text", default=PROBE_TEXT)
    ap.add_argument("--keep-failures", type=Path, default=None)
    args = ap.parse_args()

    if not FONTDUMP.exists():
        sys.exit(f"fontdump binary not found at {FONTDUMP}; run `lake build` first")

    data = args.font.read_bytes()
    rng = random.Random(args.seed)

    by_mutator = {}
    violations = []
    start = time.time()
    with tempfile.NamedTemporaryFile(suffix=".ttf", delete=False) as tf:
        tmp_path = Path(tf.name)
    try:
        for i in range(args.iters):
            mutator = rng.choice(MUTATORS)
            mutant = mutator(data, rng)
            tmp_path.write_bytes(mutant)
            rc, stderr, timed_out = run_fontdump(tmp_path, args.text, TIMEOUT_S)
            by_mutator[mutator.__name__] = by_mutator.get(mutator.__name__, 0) + 1
            v = violation(rc, stderr, timed_out)
            if v is not None:
                violations.append((i, mutator.__name__, v, len(mutant)))
                if args.keep_failures:
                    args.keep_failures.mkdir(parents=True, exist_ok=True)
                    (args.keep_failures / f"fail_{i}_{mutator.__name__}.ttf").write_bytes(mutant)
    finally:
        tmp_path.unlink(missing_ok=True)

    elapsed = time.time() - start
    print(f"{args.iters} iterations in {elapsed:.1f}s ({args.iters / max(elapsed, 1e-9):.0f}/s), seed={args.seed}")
    for name, count in sorted(by_mutator.items()):
        print(f"  {name}: {count}")
    print(f"{len(violations)} violations")
    for i, name, v, size in violations[:50]:
        print(f"  VIOLATION iter={i} mutator={name} size={size}: {v}")
    sys.exit(1 if violations else 0)


if __name__ == "__main__":
    main()
