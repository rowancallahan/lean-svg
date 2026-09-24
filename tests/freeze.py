#!/usr/bin/env python3
"""Byte-freeze harness (T117): record our output bytes, later require them.

    python3 tests/freeze.py record OUT.json [--warnings] [--jobs N]
    python3 tests/freeze.py check  OUT.json [--jobs N]

`record` renders the fixed file set below and stores, per (file, width): the
exit code, SHA-256 of the PNG bytes and, with `--warnings`, SHA-256 of
`<out>.warnings.txt` (null when a file is not written). `check` re-renders the
manifest's set with the manifest's `--warnings` setting, lists every
difference (missing/extra entries, exit code, PNG, warnings) in sorted order
with a summary, and exits 1 on any difference.

File set (same widths as the chart review):
  resvg      tests/corpora/resvg-test-suite/tests/**/*.svg  at 100 and 200 px
  local      tests/svg/*.svg                                 at native size
             (no --width, as tests/run_tests.py renders them)
  realworld  tests/corpora/realworld/**/*.svg                at 1000 px (all of
             them since T115 crops an over-budget filter region to the image)

The binary must print nothing: any stdout/stderr output aborts the run.
"""

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "lean-svg"
CORPORA = REPO / "tests" / "corpora"
TIMEOUT = 300  # seconds per render; a timeout aborts the run
FORMAT = 1


def file_set():
    """Sorted list of (key, svg path, width); key = "set/rel@width"."""
    sets = [
        ("resvg", CORPORA / "resvg-test-suite" / "tests", "**/*.svg"),
        ("local", REPO / "tests" / "svg", "*.svg"),
        ("realworld", CORPORA / "realworld", "**/*.svg"),
    ]
    out = []
    for name, base, pattern in sets:
        files = sorted(p for p in base.glob(pattern) if p.is_file())
        assert files, "no files for set %s under %s (run scripts/cloud-setup.sh)" % (name, base)
        for p in files:
            rel = p.relative_to(base).as_posix()
            if name == "resvg":
                widths = [100, 200]
            elif name == "local":
                widths = [None]
            else:
                widths = [1000]
            out += [("%s/%s@%s" % (name, rel, w or "native"), p, w) for w in widths]
    keys = [k for k, _, _ in out]
    assert len(keys) == len(set(keys))
    return sorted(out, key=lambda t: t[0])


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def render(binary, svg, width, warnings, tmp, slot):
    png = Path(tmp) / ("%d.png" % slot)
    wtxt = Path(str(png) + ".warnings.txt")
    assert not png.exists() and not wtxt.exists()
    cmd = ([str(binary), str(svg), str(png)] + (["--width", str(width)] if width else [])
           + (["--warnings"] if warnings else []))
    proc = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT)
    assert proc.stdout == b"" and proc.stderr == b"", "output on stdout/stderr: %s" % " ".join(cmd)
    entry = {"exit": proc.returncode, "png": sha(png)}
    if warnings:
        entry["warnings"] = sha(wtxt)
    else:
        assert not wtxt.exists(), "warnings file written without --warnings: %s" % svg
    png.unlink(missing_ok=True)
    wtxt.unlink(missing_ok=True)
    return entry


def render_all(binary, warnings, jobs):
    items = file_set()
    with tempfile.TemporaryDirectory(prefix="freeze-") as tmp:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            results = list(pool.map(lambda iw: render(binary, iw[1][1], iw[1][2], warnings, tmp, iw[0]),
                                    enumerate(items)))
    return {k: r for (k, _, _), r in zip(items, results)}


def git_head():
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True,
                          text=True, check=True).stdout.strip()


def diff(old, new):
    """Sorted list of difference lines between two entry maps."""
    lines = []
    for k in sorted(set(old) | set(new)):
        if k not in new:
            lines.append("MISSING  %s (in manifest, not in file set)" % k)
        elif k not in old:
            lines.append("EXTRA    %s (in file set, not in manifest)" % k)
        else:
            for field in ("exit", "png", "warnings"):
                if old[k].get(field) != new[k].get(field):
                    lines.append("%-8s %s: %s -> %s" % (field.upper(), k, old[k].get(field), new[k].get(field)))
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("record", "check"))
    ap.add_argument("manifest")
    ap.add_argument("--warnings", action="store_true", help="record: also hash <out>.warnings.txt")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--bin", default=str(DEFAULT_BIN))
    args = ap.parse_args()
    binary = Path(args.bin).resolve()
    assert binary.is_file(), "lean-svg binary not found at %s (lake build first)" % binary
    assert args.jobs >= 1
    manifest = Path(args.manifest)

    if args.mode == "record":
        assert not manifest.exists(), "%s exists; refusing to overwrite" % manifest
        entries = render_all(binary, args.warnings, args.jobs)
        doc = {"format": FORMAT, "commit": git_head(), "warnings": args.warnings, "entries": entries}
        manifest.write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        print("recorded %d renders to %s" % (len(entries), manifest))
        return 0

    doc = json.loads(manifest.read_text(encoding="utf-8"))
    assert doc["format"] == FORMAT, "unknown manifest format %r" % doc["format"]
    assert not args.warnings or doc["warnings"], "--warnings given but the manifest was recorded without it"
    new = render_all(binary, doc["warnings"], args.jobs)
    lines = diff(doc["entries"], new)
    for line in lines:
        print(line)
    kinds = {}
    for line in lines:
        kinds[line.split()[0]] = kinds.get(line.split()[0], 0) + 1
    print("checked %d renders against %s (recorded at %s): %s" % (
        len(new), manifest, doc["commit"][:12],
        "identical" if not lines else "%d differences (%s)" % (
            len(lines), ", ".join("%s %d" % kv for kv in sorted(kinds.items())))))
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
