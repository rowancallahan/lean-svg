#!/usr/bin/env python3
"""T98/T98b: strict mode, `--warnings`, exit codes, no stdout/stderr.

Runs the built `lean-svg` binary on small inline SVGs and asserts:
  * strict (default) with warnings: a `font-family` that selects no embedded
    font draws in Noto Sans, exit 2, the PNG only (no warnings file);
  * `--warnings` with warnings: exit 2, the PNG and `<png>.warnings.txt`
    (one deduplicated line); at most `Warn.maxWarnings` (32) lines;
  * no warnings (an embedded family, or generic `sans-serif`/`system-ui`):
    exit 0 and one file, in both modes;
  * no-clobber: an existing PNG makes either mode exit 1 and write nothing;
    under `--warnings` an existing warnings file does too, even for a render
    with no warnings; strict mode never touches the warnings path;
  * failures (bad arguments, unreadable input) exit 1 and write nothing;
  * no run writes a single byte to stdout or stderr.

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
GENERIC = """<svg xmlns="http://www.w3.org/2000/svg" width="200" height="60">
  <text x="10" y="40" font-family="%s" font-size="30">Text</text>
</svg>
"""
NEGATIVE = """<svg xmlns="http://www.w3.org/2000/svg" width="200" height="60">
  <text x="10" y="40" font-family="Noto Sans" font-size="-30">Text</text>
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


def silent(args):
    r = subprocess.run([str(BIN)] + args, capture_output=True, timeout=60)
    assert r.stdout == b"" and r.stderr == b"", (args, r.stdout, r.stderr)
    return r.returncode


def run(tmp: Path, svg_text: str, name: str, *flags: str):
    svg = tmp / (name + ".svg")
    svg.write_text(svg_text)
    png = tmp / (name + ".png")
    warn = Path(str(png) + ".warnings.txt")
    return silent([str(svg), str(png), *flags]), png, warn


def ink(png: Path) -> int:
    from PIL import Image

    return Image.open(png).convert("RGBA").getchannel("A").getextrema()[1]


def main() -> None:
    assert BIN.is_file(), f"{BIN} missing: run `lake build`"
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)

        rc, png, warn = run(tmp, MISSING, "strict")
        assert rc == 2, rc
        assert png.is_file() and ink(png) > 0, "missing family must draw (Noto Sans fallback)"
        assert sorted(p.name for p in tmp.iterdir()) == ["strict.png", "strict.svg"]
        print("-- strict with warnings: exit 2, one file")

        rc, png, warn = run(tmp, MISSING, "missing", "--warnings")
        assert rc == 2, rc
        assert png.is_file() and ink(png) > 0
        assert png.read_bytes() == (tmp / "strict.png").read_bytes()
        lines = warn.read_text().splitlines()
        assert lines == ['font-family "Source Sans Pro" not available; used Noto Sans'], lines
        print("-- --warnings with warnings: exit 2, PNG + deduplicated warnings file")

        for flags in ([], ["--warnings"]):
            rc, png, warn = run(tmp, PRESENT, "present" + "".join(flags), *flags)
            assert rc == 0 and png.is_file() and not warn.exists(), (flags, rc)
        for fam in ("sans-serif", "system-ui", "Foo, sans-serif"):
            rc, png, warn = run(tmp, GENERIC % fam, "gen", "--warnings")
            assert rc == 0 and not warn.exists(), (fam, rc)
            png.unlink()
        rc, png, warn = run(tmp, GENERIC % "serif", "serif", "--warnings")
        assert rc == 2 and warn.is_file(), rc
        print("-- no warnings (embedded family, sans-serif, system-ui): exit 0, one file")

        rc, png, warn = run(tmp, NEGATIVE, "negative", "--warnings")
        assert rc == 2, rc
        assert ink(png) == 0, "negative font-size must draw nothing"
        assert warn.read_text().splitlines() == ["negative font-size; text not drawn"]
        print("-- negative font-size: nothing drawn, exit 2, one warning")

        rc, png, warn = run(tmp, MANY, "many", "--warnings")
        assert rc == 2, rc
        lines = warn.read_text().splitlines()
        assert len(lines) == 32 and len(set(lines)) == 32, len(lines)
        print("-- bounded: 40 distinct missing families -> 32 lines")

        # no-clobber, PNG path taken: nothing written in either mode.
        for flags in ([], ["--warnings"]):
            png = tmp / "nc_png.png"
            warn = Path(str(png) + ".warnings.txt")
            png.write_bytes(b"sentinel")
            rc, _, _ = run(tmp, MISSING, "nc_png", *flags)
            assert rc == 1, (flags, rc)
            assert png.read_bytes() == b"sentinel" and not warn.exists()
            png.unlink()
        # --warnings, warnings path taken: nothing written, even though this
        # render has no warnings of its own.
        png = tmp / "nc_warn.png"
        warn = Path(str(png) + ".warnings.txt")
        warn.write_text("sentinel\n")
        rc, _, _ = run(tmp, PRESENT, "nc_warn", "--warnings")
        assert rc == 1, rc
        assert not png.exists() and warn.read_text() == "sentinel\n"
        # strict never looks at the warnings path: it writes the PNG only.
        rc, _, _ = run(tmp, MISSING, "nc_warn")
        assert rc == 2 and png.is_file() and warn.read_text() == "sentinel\n", rc
        print("-- no-clobber: an existing PNG (or warnings file under --warnings) -> exit 1")

        before = sorted(p.name for p in tmp.iterdir())
        svg = str(tmp / "present.svg")
        for args in ([], [svg], [svg, str(tmp / "a.png"), "--bogus"],
                     [svg, str(tmp / "b.png"), "--width", "x"],
                     [svg, str(tmp / "c.png"), str(tmp / "d.png")],
                     [str(tmp / "absent.svg"), str(tmp / "e.png")],
                     [svg, str(tmp / "nodir" / "f.png")]):
            assert silent(args) == 1, args
        assert sorted(p.name for p in tmp.iterdir()) == before
        print("-- failures (bad arguments, unreadable input, unwritable output): exit 1")
    print("warnings ok")


if __name__ == "__main__":
    main()
