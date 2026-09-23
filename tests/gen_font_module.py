#!/usr/bin/env python3
"""Generate a Lean module embedding a subsetted TrueType font (T25).

Runs `pyftsubset` on an input `.ttf` (after pinning a variable font to one
static instance with `--instance`), moves the `loca`, `hmtx`, `vmtx` and
`glyf` tables to the end of the file (T94), then base64-encodes the result
into `LeanSvg/Fonts/<Module>.lean` as two `Array String`s of short chunks
(rather than one giant string literal — measured to keep `lake build` fast,
see the T25 Report): `front`, every byte before `loca` (all the other tables,
decoded whole when the font is first used), and `tail`, the four big
per-glyph tables, which `Font.parseEmbedded` fonts read a few bytes at a time
straight out of the chunks.  Plus `def coverage : String`, the subset's
cmap as packed codepoint ranges (`Font.decodeRanges`), so font fallback can
pick a font without decoding it (T91; base64 replaced T25's hex to cut the
embedded size from 2x to 4/3x).

    python3 tests/gen_font_module.py <input.ttf> <ModuleName> [options]
    python3 tests/gen_font_module.py --from-module <ModuleName>

The second form re-emits an existing module in the current format from the
font bytes it already embeds (keeping its header lines), without the source
`.ttf`.

Options:
    --unicodes RANGES     passed straight to pyftsubset (default: Basic Latin,
                           Latin-1 Supplement, Latin Extended-A, General
                           Punctuation)
    --chunk-chars N       base64 characters per chunk string, a multiple of 4
                           (default 20000, i.e. 15 KB of font data per chunk)
    --layout-features F   passed to pyftsubset (default: kern; T93's shaped
                           fonts keep every GSUB/GPOS feature with '*')
    --instance AXIS=V,..  instantiate a variable font at this location first
                           (fontTools.varLib.instancer; unlisted axes keep
                           their default)
    --pyftsubset PATH     path to the pyftsubset executable (default: look on
                           PATH, then next to this interpreter's user base)
    --out PATH            output .lean path (default LeanSvg/Fonts/<Module>.lean)
    --keep-subset PATH    also save the intermediate subsetted .ttf here

Prints the exact pyftsubset command and the before/after sizes, for the
task's Report.
"""

from __future__ import annotations

import argparse
import base64
import re
import shutil
import site
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Basic Latin, Latin-1 Supplement, Latin Extended-A, General Punctuation, plus
# U+20AC (Euro sign, Currency Symbols block) so that check_font.py's default
# probe string -- which the T25 spec itself defines to include "€" -- lands on
# a real glyph rather than trivially matching .notdef on both sides.
DEFAULT_UNICODES = "U+0020-007F,U+00A0-00FF,U+0100-017F,U+2000-206F,U+20AC"
DEFAULT_CHUNK_CHARS = 20000


def find_pyftsubset(explicit: str | None) -> str:
    if explicit:
        return explicit
    found = shutil.which("pyftsubset")
    if found:
        return found
    candidate = Path(site.getuserbase()) / "bin" / "pyftsubset"
    if candidate.exists():
        return str(candidate)
    sys.exit(
        "pyftsubset not found on PATH or in the user site bin directory; "
        "install with: pip3 install --user fonttools"
    )


def subset_font(pyftsubset: str, src: Path, dst: Path, unicodes: str, features: str) -> list[str]:
    cmd = [
        pyftsubset,
        str(src),
        f"--output-file={dst}",
        f"--unicodes={unicodes}",
        "--no-hinting",
        f"--layout-features={features}",
        "--glyph-names",
        "--notdef-outline",
    ]
    subprocess.run(cmd, check=True)
    return cmd


def pack_ranges(data: bytes) -> str:
    """The font's cmap (codepoints mapped to a glyph other than .notdef) as
    sorted inclusive ranges, 6 bytes each (24-bit first, 24-bit last), base64."""
    import io
    from fontTools.ttLib import TTFont

    cps = sorted(c for c, g in TTFont(io.BytesIO(data)).getBestCmap().items() if g != ".notdef")
    assert cps, "font maps no codepoint"
    ranges = []
    for c in cps:
        if ranges and ranges[-1][1] + 1 == c:
            ranges[-1][1] = c
        else:
            ranges.append([c, c])
    packed = b"".join(a.to_bytes(3, "big") + b.to_bytes(3, "big") for a, b in ranges)
    return base64.b64encode(packed).decode()


def tables(data: bytes) -> list[tuple[bytes, int, int, int]]:
    """The table directory: (tag, checksum, offset, length) per record."""
    n = struct.unpack(">H", data[4:6])[0]
    return [struct.unpack(">4sIII", data[12 + 16 * i : 28 + 16 * i]) for i in range(n)]


# Read a few bytes per glyph, so kept apart from the eagerly decoded front, in
# this order at the end of the file (`Font.parseEmbedded`).
TAIL = [b"loca", b"hmtx", b"vmtx", b"glyf"]


def tail_last(data: bytes) -> bytes:
    """The same font with its tables laid out in their current order except
    that the `TAIL` tables come last, in `TAIL` order, each table 4-byte
    aligned, the directory (whose record order is unchanged) pointing at the
    new offsets.  Every table's bytes are unchanged, so the font parses to
    exactly the same glyphs and metrics."""
    dirs = tables(data)
    tags = [t for t, _, _, _ in dirs]
    for t in (b"loca", b"hmtx", b"glyf"):
        assert tags.count(t) == 1, tags
    head_len = 12 + 16 * len(dirs)
    order = sorted(dirs, key=lambda d: (TAIL.index(d[0]) if d[0] in TAIL else -1, d[2]))
    body = bytearray(data[:head_len])
    new_off = {}
    for tag, _, off, ln in order:
        body += b"\0" * (-len(body) % 4)
        new_off[tag] = len(body)
        body += data[off : off + ln]
    for i, (tag, cs, _, ln) in enumerate(dirs):
        struct.pack_into(">4sIII", body, 12 + 16 * i, tag, cs, new_off[tag], ln)
    out = bytes(body)
    for (tag, _, off, ln), (tag2, _, off2, ln2) in zip(dirs, tables(out)):
        assert tag == tag2 and ln == ln2 and data[off : off + ln] == out[off2 : off2 + ln2], tag
    g = [d for d in tables(out) if d[0] == b"glyf"][0]
    assert g[2] + g[3] == len(out) and g[2] % 4 == 0
    return out


def tail_offset(data: bytes) -> int:
    return min(o for t, _, o, _ in tables(data) if t in TAIL)


def chunked(b: bytes, chunk_chars: int) -> list[str]:
    b64 = base64.b64encode(b).decode()
    return [b64[i : i + chunk_chars] for i in range(0, len(b64), chunk_chars)]


def to_lean_module(data: bytes, module: str, chunk_chars: int, header: list[str]) -> str:
    assert chunk_chars % 4 == 0
    data = tail_last(data)
    tail_off = tail_offset(data)
    assert all(o >= tail_off for t, _, o, _ in tables(data) if t in TAIL)
    assert all(o + n <= tail_off for t, _, o, n in tables(data) if t not in TAIL)
    front = chunked(data[:tail_off], chunk_chars)
    tail = chunked(data[tail_off:], chunk_chars)
    lines = [
        "-- Generated by tests/gen_font_module.py. Do not edit by hand.",
        f"-- {len(data)} bytes of embedded, subsetted TrueType font data.",
    ]
    lines += [f"-- {h}" for h in header]
    lines += [
        "import LeanSvg.Font",
        "",
        f"namespace LeanSvg.Fonts.{module}",
        "",
        "/-- Base64 of every font byte before the `loca`, `hmtx`, `vmtx` and `glyf`",
        "tables (the generator moves those to the end), split into short chunks so",
        "`lake build` never has to parse one giant string literal (see the T25",
        "Report in tasks/T25-font-parser.md for the measured effect). -/",
        "def front : Array String := #[",
    ]
    lines += [f'  "{c}",' for c in front]
    lines += [
        "]",
        "",
        f"/-- Base64 of the rest (`loca`, `hmtx`, `vmtx`, `glyf`), {chunk_chars // 4 * 3} bytes per",
        "chunk; read a few bytes at a time (`Font.parseEmbedded`). -/",
        "def tail : Array String := #[",
    ]
    lines += [f'  "{c}",' for c in tail]
    lines += [
        "]",
        "",
        "/-- The font: `front` is decoded when it is first used, each glyph as it is drawn. -/",
        f"def font (_ : Unit) : Option LeanSvg.Font := LeanSvg.Font.parseEmbedded front tail {chunk_chars // 4 * 3} {len(data) - tail_off}",
        "",
        "/-- The whole font file (for `fontdump`). -/",
        "def bytes (_ : Unit) : ByteArray := LeanSvg.Font.base64DecodeChunks (front ++ tail)",
        "",
        "/-- The font's cmap coverage, for `LeanSvg.Font.decodeRanges`. -/",
        f'def coverage : String := "{pack_ranges(data)}"',
        "",
        f"end LeanSvg.Fonts.{module}",
        "",
    ]
    return "\n".join(lines)


def module_bytes(path: Path) -> tuple[bytes, list[str]]:
    """The font bytes and extra header lines of an existing generated module
    (either the T91 `chunks` form or this one's `front`/`tail` form)."""
    src = path.read_text()
    header = [l[3:] for l in src.splitlines()[2:] if l.startswith("-- ")]
    arrays = re.findall(r"def (?:chunks|front|tail) : Array String := #\[(.*?)\n\]", src, re.S)
    assert arrays, path
    data = b"".join(base64.b64decode("".join(re.findall(r'"([^"]*)"', a))) for a in arrays)
    n = int(re.search(r"^-- (\d+) bytes of embedded", src, re.M).group(1))
    assert len(data) == n, (len(data), n)
    return data, header


def instantiate(src: Path, spec: str, dst: Path) -> None:
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer

    loc = {k: float(v) for k, v in (kv.split("=") for kv in spec.split(","))}
    instancer.instantiateVariableFont(TTFont(src), loc).save(dst)


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--from-module":
        module = sys.argv[2]
        out = REPO / "LeanSvg" / "Fonts" / f"{module}.lean"
        data, header = module_bytes(out)
        out.write_text(to_lean_module(data, module, DEFAULT_CHUNK_CHARS, header))
        print(f"{module}: {len(data)} bytes -> {out.relative_to(REPO)} ({out.stat().st_size} bytes of Lean source)")
        return
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ttf", type=Path)
    ap.add_argument("module", help="Lean module name, e.g. NotoSans")
    ap.add_argument("--unicodes", default=DEFAULT_UNICODES)
    ap.add_argument("--chunk-chars", type=int, default=DEFAULT_CHUNK_CHARS)
    ap.add_argument("--instance", default=None)
    ap.add_argument("--layout-features", default="kern")
    ap.add_argument("--header", action="append", default=[], help="extra comment line (source, version, licence)")
    ap.add_argument("--pyftsubset", default=None)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--keep-subset", type=Path, default=None)
    args = ap.parse_args()

    pyftsubset = find_pyftsubset(args.pyftsubset)
    subset_path = args.keep_subset or Path(f"/tmp/{args.module}.subset.ttf")
    src = args.ttf
    if args.instance:
        src = Path(f"/tmp/{args.module}.instance.ttf")
        instantiate(args.ttf, args.instance, src)
    cmd = subset_font(pyftsubset, src, subset_path, args.unicodes, args.layout_features)
    data = subset_path.read_bytes()

    out = args.out or (REPO / "LeanSvg" / "Fonts" / f"{args.module}.lean")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(to_lean_module(data, args.module, args.chunk_chars, args.header))

    print("command:", " ".join(cmd))
    print(
        f"{args.ttf.name}: {args.ttf.stat().st_size} bytes -> "
        f"subset {len(data)} bytes -> {out.relative_to(REPO)} "
        f"({out.stat().st_size} bytes of Lean source)"
    )


if __name__ == "__main__":
    main()
