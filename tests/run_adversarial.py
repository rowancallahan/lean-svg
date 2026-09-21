#!/usr/bin/env python3
"""Safety harness: feed hostile inputs to microsvg and check that it never
crashes, never hangs, and never writes a file other than the requested output.

Inputs are the checked-in corpus in tests/adversarial/ plus a set of generated
cases written fresh into tests/out/adversarial_gen/ on every run.

Each input is rendered into its own fresh temporary directory, and the run is a
VIOLATION unless all of the following hold:
  * the process exits 0 or 1 within the timeout (a signal shows up as a
    negative return code on macOS and is never acceptable);
  * stderr mentions no panic, stack overflow, internal error or uncaught
    exception;
  * out.png exists if and only if the return code is 0;
  * the temporary directory contains nothing but out.png;
  * any out.png produced starts with the PNG signature and opens in Pillow.
"""

import argparse
import random
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SVG_DIR = REPO / "tests" / "svg"
ADV_DIR = REPO / "tests" / "adversarial"
OUT_DIR = REPO / "tests" / "out"
GEN_DIR = OUT_DIR / "adversarial_gen"
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "microsvg"

RENDER_TIMEOUT = 120  # seconds
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
CRASH_MARKERS = ["PANIC", "panic", "Stack overflow", "INTERNAL", "uncaught"]


# --------------------------------------------------------------------------
# generated cases
# --------------------------------------------------------------------------


def generate_cases():
    """(Re)create tests/out/adversarial_gen with the generated hostile inputs."""
    if GEN_DIR.exists():
        shutil.rmtree(GEN_DIR)
    GEN_DIR.mkdir(parents=True)

    def write_text(name, text):
        (GEN_DIR / name).write_text(text, encoding="utf-8")

    def write_bytes(name, data):
        (GEN_DIR / name).write_bytes(data)

    def nested(depth):
        head = '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        return (
            head
            + "<g>" * depth
            + '<rect x="10" y="10" width="80" height="80" fill="#3366cc"/>'
            + "</g>" * depth
            + "\n</svg>\n"
        )

    # parser caps nesting depth at 64: 200 should be rejected, 60 accepted.
    write_text("deep_nesting_200.svg", nested(200))
    write_text("deep_nesting_60.svg", nested(60))

    # 300k tiny rects: large but legitimate input.
    rects = [
        '<rect x="%d" y="%d" width="1" height="1" fill="#204080"/>'
        % (i % 200, (i // 200) % 200)
        for i in range(300_000)
    ]
    write_text(
        "many_elements.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">\n'
        + "\n".join(rects)
        + "\n</svg>\n",
    )

    # a number literal with two million digits.
    write_text(
        "long_number.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        '<rect x="%s" y="10" width="10" height="10" fill="#000"/>\n</svg>\n'
        % ("9" * 2_000_000),
    )

    # a path with half a million line segments.
    zigzag = "".join(
        " L %d %d" % (i % 200, 10 if i % 2 else 190) for i in range(500_000)
    )
    write_text(
        "huge_path.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">\n'
        '<path d="M 0 0%s" fill="none" stroke="#000"/>\n</svg>\n' % zigzag,
    )

    write_text(
        "giant_stroke.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        '<line x1="10" y1="10" x2="90" y2="90" stroke="#000" stroke-width="1e9"/>\n'
        "</svg>\n",
    )

    write_text(
        "negative_dims.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="-5" height="-5">\n'
        '<rect x="0" y="0" width="10" height="10" fill="#000"/>\n</svg>\n',
    )

    # 64 KiB of deterministic noise that is not XML at all.
    write_bytes(
        "random_bytes.bin",
        bytes(random.Random(1234).getrandbits(8) for _ in range(64 * 1024)),
    )

    # every corpus file cut in half mid-document.
    for svg in sorted(SVG_DIR.glob("*.svg")):
        data = svg.read_bytes()
        write_bytes("truncated_%s.svg" % svg.stem, data[: len(data) // 2])

    # 1000 NUL bytes buried in an attribute value.
    write_bytes(
        "nul_bytes.svg",
        b'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        b'<rect id="a' + b"\x00" * 1000 + b'b" x="10" y="10" width="80" '
        b'height="80" fill="#3366cc"/>\n</svg>\n',
    )

    # non-ASCII bytes in element and attribute names.
    write_bytes(
        "unicode_names.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        "<rëct wídth=\"80\" héight=\"80\" x=\"10\" y=\"10\" fill=\"#3366cc\"/>\n"
        '<группа ширина="5"/>\n'
        "</svg>\n".encode("utf-8"),
    )

    # ~1 MB of text content inside a single <text> element.
    words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing"]
    rnd = random.Random(42)
    chunks = []
    total = 0
    while total < 1_000_000:
        chunk = rnd.choice(words) + " "
        chunks.append(chunk)
        total += len(chunk)
    big_text = "".join(chunks)
    write_text(
        "text_1mb.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        '<text x="10" y="50" font-size="12">%s</text>\n</svg>\n' % big_text,
    )

    # a <text> with 10 000 nested <tspan> elements.
    tspan_depth = 10_000
    write_text(
        "text_nested_tspans.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        '<text x="10" y="50" font-size="12">'
        + "<tspan>" * tspan_depth
        + "hi"
        + "</tspan>" * tspan_depth
        + "</text>\n</svg>\n",
    )

    # a text element with an enormous font-size.
    write_text(
        "text_huge_font_size.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        '<text x="10" y="50" font-size="1e9">hi</text>\n</svg>\n',
    )

    # a text element whose x attribute is a list of 100 000 numbers.
    x_list = " ".join(str(i % 100) for i in range(100_000))
    write_text(
        "text_x_list_100k.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        '<text x="%s" y="50" font-size="12">hi</text>\n</svg>\n' % x_list,
    )

    return sorted(GEN_DIR.iterdir())


# --------------------------------------------------------------------------
# running one case
# --------------------------------------------------------------------------


def check_png(path):
    """Return an error string if the produced PNG is not a readable PNG."""
    with open(path, "rb") as fh:
        head = fh.read(8)
    if head != PNG_SIGNATURE:
        return "output is not a PNG (magic bytes %s)" % head.hex()
    try:
        with Image.open(path) as img:
            img.load()
    except Exception as exc:
        return "Pillow could not open the output: %s" % exc
    return None


def run_case(path, binary, label):
    result = {
        "name": label,
        "rc": None,
        "ms": None,
        "output": False,
        "stderr": "",
        "violations": [],
    }
    tmpdir = Path(tempfile.mkdtemp(prefix="microsvg_adv_"))
    out_png = tmpdir / "out.png"
    try:
        start = time.perf_counter()
        timed_out = False
        try:
            proc = subprocess.run(
                [str(binary), str(path), str(out_png)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=RENDER_TIMEOUT,
            )
            rc = proc.returncode
            stderr = proc.stderr.decode("utf-8", "replace")
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            rc = None
            stderr = (exc.stderr or b"").decode("utf-8", "replace")
        result["ms"] = (time.perf_counter() - start) * 1000.0
        result["rc"] = rc
        result["stderr"] = stderr.strip()

        if timed_out:
            result["violations"].append("timed out after %ds" % RENDER_TIMEOUT)
        elif rc not in (0, 1):
            result["violations"].append(
                "return code %d (expected 0 or 1%s)"
                % (rc, "; negative means a signal" if rc < 0 else "")
            )

        for marker in CRASH_MARKERS:
            if marker in stderr:
                result["violations"].append("stderr contains %r" % marker)

        exists = out_png.is_file()
        result["output"] = exists
        if not timed_out:
            if rc == 0 and not exists:
                result["violations"].append("exited 0 but wrote no out.png")
            if rc != 0 and exists:
                result["violations"].append("exited %d but still wrote out.png" % rc)

        strays = sorted(p.name for p in tmpdir.iterdir() if p.name != "out.png")
        if strays:
            result["violations"].append(
                "stray files in the output directory: %s" % ", ".join(strays)
            )

        if exists:
            problem = check_png(out_png)
            if problem:
                result["violations"].append(problem)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return result


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

COLUMNS = [
    ("name", 28, "<"),
    ("rc", 5, ">"),
    ("ms", 10, ">"),
    ("output?", 7, "<"),
    ("stderr", 46, "<"),
    ("status", 9, "<"),
]


def fmt_row(values, columns=COLUMNS):
    return "  ".join(
        "{:{align}{width}}".format(str(v), align=col[2], width=col[1])
        for v, col in zip(values, columns)
    )


def sized_columns(results):
    """Widen the name column so the longest case name still lines up."""
    columns = list(COLUMNS)
    width = max([len(r["name"]) for r in results] + [len(columns[0][0])])
    columns[0] = (columns[0][0], width, columns[0][2])
    return columns


def excerpt(stderr, width=46):
    if not stderr:
        return ""
    line = stderr.splitlines()[0]
    line = "".join(ch if ch.isprintable() else "." for ch in line)
    return line if len(line) <= width else line[: width - 3] + "..."


def print_table(results):
    columns = sized_columns(results)
    header = fmt_row([c[0] for c in columns], columns)
    print(header)
    print("-" * len(header))
    for r in results:
        print(
            fmt_row(
                [
                    r["name"],
                    "timeout" if r["rc"] is None else r["rc"],
                    "%.1f" % r["ms"],
                    "yes" if r["output"] else "no",
                    excerpt(r["stderr"]),
                    "OK" if not r["violations"] else "VIOLATION",
                ],
                columns,
            )
        )
        for v in r["violations"]:
            print("      ! %s" % v)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", help="only run cases whose name contains SUBSTR")
    parser.add_argument(
        "--bin", default=str(DEFAULT_BIN), help="path to the microsvg binary"
    )
    args = parser.parse_args()

    binary = Path(args.bin).resolve()
    if not binary.is_file():
        print("microsvg binary not found at %s" % binary, file=sys.stderr)
        print("build it first:  lake build", file=sys.stderr)
        return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("generating adversarial cases in %s ..." % GEN_DIR)
    generated = generate_cases()

    cases = [(p, "corpus/" + p.name) for p in sorted(ADV_DIR.iterdir()) if p.is_file()]
    cases += [(p, "gen/" + p.name) for p in generated]
    if args.filter:
        cases = [c for c in cases if args.filter in c[1]]
    if not cases:
        print("no adversarial cases to run", file=sys.stderr)
        return 2

    print("running %d cases (timeout %ds each)\n" % (len(cases), RENDER_TIMEOUT))
    results = [run_case(path, binary, label) for path, label in cases]
    print_table(results)

    violations = [r for r in results if r["violations"]]
    print()
    print(
        "%d/%d cases clean, %d with violations"
        % (len(results) - len(violations), len(results), len(violations))
    )
    if violations:
        print("violations in: %s" % ", ".join(r["name"] for r in violations))
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
