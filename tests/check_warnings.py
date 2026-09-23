#!/usr/bin/env python3
"""T98: the warnings file `<output>.warnings.txt`.

Runs the built `lean-svg` binary on small inline SVGs and asserts:
  * present: a `font-family` that selects no embedded font draws in Noto Sans,
    exits 0, writes the PNG and a warnings file (one deduplicated line), and
    prints a one-line note on stderr;
  * absent: an embedded family exits 0 with no warnings file and no stderr;
  * bounded: many distinct missing families give at most `Warn.maxWarnings`
    (32) lines;
  * no-clobber: an existing warnings file, or an existing PNG, makes the run
    fail with exit 1 before anything is written, leaving both paths as they
    were -- even for a render that would produce no warnings.

    python3 tests/check_warnings.py
"""
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIN = REPO / ".lake" / "build" / "bin" / "lean-svg"

MISSING = """<svg xmlns="http://www.w3.org/2000/svg" width="200" height="60">
  <text x="10" y="40" font-family="Source Sans Pro" font-size="30">Text</text>
  <text x="100" y="40" font-family="Source Sans Pro" font-size="30">Again</text>
</svg>
"""
PRESENT = """<svg xmlns="http://www.w3.org/2000/svg" width="200" height="60">
  <text x="10" y="40" font-family="Noto Sans" font-size="30">Text</text>
</svg>
"""
MANY = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="60">\n'
    + "".join(
        '<text x="10" y="40" font-family="Missing%d" font-size="30">T</text>\n' % i
        for i in range(40)
    )
    + "</svg>\n"
)


def run(tmp: Path, svg_text: str, name: str):
    svg = tmp / (name + ".svg")
    svg.write_text(svg_text)
    png = tmp / (name + ".png")
    warn = Path(str(png) + ".warnings.txt")
    r = subprocess.run([str(BIN), str(svg), str(png)], capture_output=True, text=True, timeout=60)
    return r, png, warn


def ink(png: Path) -> int:
    from PIL import Image

    return Image.open(png).convert("RGBA").getchannel("A").getextrema()[1]


def main() -> None:
    assert BIN.is_file(), f"{BIN} missing: run `lake build`"
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)

        r, png, warn = run(tmp, MISSING, "missing")
        assert r.returncode == 0, r.stderr
        assert png.is_file() and ink(png) > 0, "missing family must draw (Noto Sans fallback)"
        assert warn.is_file(), "warnings file not written"
        lines = warn.read_text().splitlines()
        assert lines == ['font-family "Source Sans Pro" not available; used Noto Sans'], lines
        assert r.stderr.strip() == f"lean-svg: warnings written to {warn}", r.stderr
        print("-- present: warnings file written, deduplicated, stderr note")

        r, png, warn = run(tmp, PRESENT, "present")
        assert r.returncode == 0, r.stderr
        assert png.is_file() and not warn.exists(), "no warnings: no second file"
        assert r.stderr == "", r.stderr
        print("-- absent: no warnings file")

        r, png, warn = run(tmp, MANY, "many")
        assert r.returncode == 0, r.stderr
        lines = warn.read_text().splitlines()
        assert len(lines) == 32 and len(set(lines)) == 32, len(lines)
        print("-- bounded: 40 distinct missing families -> 32 lines")

        # no-clobber, warnings path taken: nothing written, even though this
        # render has no warnings of its own.
        png = tmp / "nc1.png"
        warn = Path(str(png) + ".warnings.txt")
        warn.write_text("sentinel\n")
        r, _, _ = run(tmp, PRESENT, "nc1")
        assert r.returncode == 1, (r.returncode, r.stderr)
        assert "refusing to overwrite" in r.stderr, r.stderr
        assert not png.exists() and warn.read_text() == "sentinel\n"
        # no-clobber, PNG path taken: no warnings file appears either.
        png = tmp / "nc2.png"
        warn = Path(str(png) + ".warnings.txt")
        png.write_bytes(b"sentinel")
        r, _, _ = run(tmp, MISSING, "nc2")
        assert r.returncode == 1, (r.returncode, r.stderr)
        assert png.read_bytes() == b"sentinel" and not warn.exists()
        print("-- no-clobber: existing warnings file or PNG -> exit 1, nothing written")
    print("warnings ok")


if __name__ == "__main__":
    main()
