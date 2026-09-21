#!/usr/bin/env python3
"""Build the public lean-svg site (GitHub Pages artifact).

    python3 site/gen_site.py --out site/_build
    python3 site/gen_site.py --out site/_build --reuse   # skip the harness run

Everything under --out is generated; nothing is written back into the
repository, and nothing generated is committed (see .gitignore). The GitHub
Actions workflow in .github/workflows/pages.yml runs this and uploads --out as
the Pages artifact.

Four pages, plus a licensing page:

    index.html      the C01-C55 feature audit, statuses derived from the
                    measured pass rates in this run
    gallery.html    every resvg-suite file, three renderings + a diff
    demos.html      the project's own tests/svg/*.svg, larger
    draw.html       a browser-only drawing toy
    licensing.html  every third-party component and its licence

Comparison columns are, in this order: lean-svg (this renderer), resvg 0.48.1
(the oracle), and the visitor's own browser rendering the original file. The
browser column is a sanity check and is never scored. The usvg route does not
appear anywhere: it is an internal diagnostic.

**One run, one width.** Every number on the site (the headline, the per
directory table and every feature row) comes from a single
`tests/run_corpora.py --route direct --width W` run, because within-8 pass/fail
flips at the 99% threshold when the render width changes, and numbers from two
widths cannot be compared. The demos page renders at its own larger width and
says so; its numbers are never mixed with the corpus numbers.
"""

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SITE = REPO / "site"
sys.path.insert(0, str(REPO / "tests"))

import run_corpora as RC  # noqa: E402  (path must be set up first)
from gen_gallery import STATUS_GROUP, diff_image, urlpath  # noqa: E402
from run_tests import compare, load_rgba, resvg_font_args  # noqa: E402

CORPUS = "resvg"
ROUTE = "direct"  # the only route the site shows
SUITE_ROOT = RC.CORPORA_DIR / RC.CORPORA[CORPUS][0]
DEMO_DIR = REPO / "tests" / "svg"

THUMB_COLORS = 64  # palette size for the 150 px thumbnails
FULL_COLORS = 128  # palette size for the click-through images
DIFF_GAIN = 8

# Status thresholds, applied to a feature row's measured pass rate. Stated on
# the page so a visitor can check the arithmetic.
SUPPORTED_AT = 0.75
PARTIAL_AT = 0.30


# --------------------------------------------------------------------------
# the C01-C55 audit (PLAN.md, "Feature selection and corpus audit")
# --------------------------------------------------------------------------
#
# Each row names the corpus directories (and, where a feature has no directory
# of its own, the path substrings) whose files measure it; a substring written
# `!foo` removes the files it matches, which is how two rows split one shared
# directory. Directories are shared between rows on purpose — a row's files are
# a selection, not a partition, so the rows must not be summed. `override` is
# for the rows this corpus cannot measure at all; every other status is derived
# from the run.

SECTIONS = [
    ("geometry", "Geometry, styles, structure, and painting"),
    ("paint", "Paint servers, effects, and resources"),
    ("text", "Text and font compatibility"),
    ("output", "Browser features and output behavior"),
]

FEATURES = [
    ("C01", "geometry", "Basic shapes, rounded rectangles",
     ["shapes/rect", "shapes/circle", "shapes/ellipse", "shapes/line",
      "shapes/polygon", "shapes/polyline"], [], None, ""),
    ("C02", "geometry", "Paths, cubic/quadratic curves, elliptical arcs",
     ["shapes/path"], [], None, ""),
    ("C03", "geometry", "Solid colours, alpha, currentColor, RGB/HSL notation",
     ["painting/fill", "painting/color"], [], None, ""),
    ("C04", "geometry", "Nonzero / even-odd fills",
     ["painting/fill-rule", "masking/clip-rule"], [], None, ""),
    ("C05", "geometry", "Stroke widths, caps, joins, miter limits",
     ["painting/stroke", "painting/stroke-width", "painting/stroke-linecap",
      "painting/stroke-linejoin", "painting/stroke-miterlimit"], [], None, ""),
    ("C06", "geometry", "Dashes and dash offsets",
     ["painting/stroke-dasharray", "painting/stroke-dashoffset"], [], None, ""),
    ("C07", "geometry", "Non-scaling strokes (vector-effect)",
     [], [], ("not yet", "no vector-effect fixture in the suite; not implemented"), ""),
    ("C08", "geometry", "Author-specified pathLength scaling",
     [], [], ("not yet", "no pathLength fixture in the suite; not implemented"), ""),
    ("C09", "geometry", "Transforms and transform origins",
     ["structure/transform", "structure/transform-origin"], [], None, ""),
    ("C10", "geometry", "Size/units, viewBox, preserveAspectRatio",
     ["structure/svg"], ["!structure/svg/nested"], None,
     "structure/svg without its nested-viewport fixtures, which are C14"),
    ("C11", "geometry", "Groups, inheritance, display/visibility",
     ["structure/g", "painting/display", "painting/visibility"], [], None, ""),
    ("C12", "geometry", "Group/element opacity applied after compositing",
     ["painting/opacity"], [], None, ""),
    ("C13", "geometry", "Fill/stroke opacity",
     ["painting/fill-opacity", "painting/stroke-opacity"], [], None, ""),
    ("C14", "geometry", "Nested SVG viewports and overflow",
     ["painting/overflow"], ["structure/svg/nested"], None,
     "structure/svg nested-viewport fixtures plus painting/overflow"),
    ("C15", "geometry", "Inline style and simple stylesheet selectors/cascade",
     ["structure/style", "structure/style-attribute"], [], None, ""),
    ("C16", "geometry", "Advanced CSS / browser layout behaviour",
     [], [], ("out of scope", "no defined subset in this release; the suite has "
              "no directory that isolates it"), ""),
    ("C17", "geometry", "Shape-rendering hints, crisp edges",
     ["painting/shape-rendering"], [], None, ""),
    ("C18", "geometry", "Paint order (fill/stroke/markers)",
     ["painting/paint-order"], [], None, ""),
    ("C19", "geometry", "Conditional switch and language selection",
     ["structure/switch", "structure/systemLanguage"], [], None, ""),

    ("C20", "paint", "Local definitions and restricted url(#id) resolution",
     ["structure/defs"], [], None, ""),
    ("C21", "paint", "Linear gradients, stops, units, transforms",
     ["paint-servers/linearGradient", "paint-servers/stop",
      "paint-servers/stop-color", "paint-servers/stop-opacity"], [], None, ""),
    ("C22", "paint", "Radial gradients and focal-point/radius handling",
     ["paint-servers/radialGradient"], [], None, ""),
    ("C23", "paint", "Repeat/reflect gradient spread",
     [], ["spreadMethod"], None, "files named spreadMethod* in both gradient directories"),
    ("C24", "paint", "Gradient inheritance through local href chains",
     [], ["paint-servers/linearGradient/attributes-via-xlink-href",
          "paint-servers/linearGradient/stops-via-xlink-href",
          "paint-servers/radialGradient/attributes-via-xlink-href",
          "paint-servers/radialGradient/stops-via-xlink-href"], None,
     "the attributes-via / stops-via xlink-href fixtures in both gradient directories"),
    ("C25", "paint", "Repeating patterns",
     ["paint-servers/pattern"], [], None, ""),
    ("C26", "paint", "Clip paths, units, transforms, fill rules",
     ["masking/clipPath", "masking/clip-rule"], [], None, ""),
    ("C27", "paint", "CSS basic-shape clips / legacy clip rectangle",
     ["masking/clip"], [], None, ""),
    ("C28", "paint", "Alpha/luminance masks, regions and units",
     ["masking/mask"], [], None, ""),
    ("C29", "paint", "Blend modes and isolation",
     ["painting/mix-blend-mode", "painting/isolation"], [], None, ""),
    ("C30", "paint", "Markers / arrowheads / context paint",
     ["painting/marker", "painting/context"], [], None, ""),
    ("C31", "paint", "Local use/symbol reuse and expansion",
     ["structure/use", "structure/symbol"], [], None, ""),
    ("C32", "paint", "Embedded raster images (PNG/JPEG/GIF)",
     ["structure/image"],
     ["!structure/image/embedded-svg", "!structure/image/external-svg",
      "!structure/image/url-to-svg"], None,
     "structure/image without its SVG-valued fixtures, which are C33"),
    ("C33", "paint", "Embedded SVG/SVGZ images",
     [], ["structure/image/embedded-svg", "structure/image/external-svg",
          "structure/image/url-to-svg"], None,
     "the SVG-valued fixtures inside structure/image"),
    ("C34", "paint", "External images, CSS, fonts, URL/file loading",
     [], ["external"], ("out of scope",
                        "deliberate rejection: the renderer reads one input file and "
                        "writes one output file, so external references are refused"), ""),
    ("C35", "paint", "Basic filters: blur, drop shadow, offset, flood, merge",
     ["filters/feGaussianBlur", "filters/feDropShadow", "filters/feOffset",
      "filters/feFlood", "filters/feMerge", "filters/flood-color",
      "filters/flood-opacity"], [], None, ""),
    ("C36", "paint",
     "Other filters: colour matrix, transfer, blend/composite, morphology, "
     "convolution, displacement, turbulence, lighting, tile/image",
     ["filters/feBlend", "filters/feColorMatrix", "filters/feComponentTransfer",
      "filters/feComposite", "filters/feConvolveMatrix", "filters/feDiffuseLighting",
      "filters/feDisplacementMap", "filters/feDistantLight", "filters/feImage",
      "filters/feMorphology", "filters/fePointLight", "filters/feSpecularLighting",
      "filters/feSpotLight", "filters/feTile", "filters/feTurbulence",
      "filters/filter", "filters/filter-functions", "filters/enable-background"],
     [], None, ""),

    ("C37", "text", "Basic text/tspan, whitespace/entities, coordinates and rotation",
     ["text/text", "text/tspan"], [], None, ""),
    ("C38", "text", "Family selection, fallback, size, weight, style, stretch",
     ["text/font", "text/font-family", "text/font-size", "text/font-weight",
      "text/font-style", "text/font-stretch"], [], None, ""),
    ("C39", "text", "Kerning, letter/word spacing, anchors",
     ["text/font-kerning", "text/kerning", "text/letter-spacing",
      "text/word-spacing", "text/text-anchor"], [], None, ""),
    ("C40", "text", "Baselines and baseline shifts",
     ["text/alignment-baseline", "text/dominant-baseline", "text/baseline-shift"],
     [], None, ""),
    ("C41", "text", "textLength / lengthAdjust",
     ["text/textLength", "text/lengthAdjust"], [], None, ""),
    ("C42", "text", "Underline / overline / strike-through",
     ["text/text-decoration"], [], None, ""),
    ("C43", "text", "Text along paths",
     ["text/textPath"], [], None, ""),
    ("C44", "text", "Vertical writing / glyph orientation",
     ["text/writing-mode", "text/glyph-orientation-vertical",
      "text/glyph-orientation-horizontal"], [], None, ""),
    ("C45", "text", "RTL, Arabic/Indic shaping, ligatures, combining marks",
     ["text/direction", "text/unicode-bidi"], [], None,
     "the suite's shaping cases also sit inside text/text (row C37)"),
    ("C46", "text", "Emoji sequences and colour glyphs",
     ["text/color-font"], [], None, ""),
    ("C47", "text", "Small caps, font-size-adjust, text-rendering hints",
     ["text/font-variant", "text/font-size-adjust", "text/text-rendering"],
     [], None, ""),
    ("C48", "text", "Broad font-file support: CFF, collections, variable fonts, webfonts",
     ["text/font-variation-settings"], [], None,
     "only the variable-font fixtures are measurable here; the embedded faces are "
     "three Latin subsets of Noto Sans"),
    ("C49", "text", "System-font discovery or user font loading",
     [], [], ("out of scope",
              "the renderer reads no files but its input: the faces are compiled in"), ""),

    ("C50", "output", "HTML in foreignObject",
     [], [], ("out of scope", "no foreignObject element in the suite; not in this release"), ""),
    ("C51", "output", "Animation sampled at a selected time",
     [], [], ("out of scope", "no animate/set element in the suite; static renderer"), ""),
    ("C52", "output", "Scripts / events / interactivity",
     [], [], ("out of scope", "outside a static renderer's scope"), ""),
    ("C53", "output", "Explicit colour-interpolation / advanced colour management",
     [], ["color-interpolation", "icc"], None,
     "files whose name mentions colour interpolation or ICC paint"),
    ("C54", "output", "PNG dimensions, transparency, background, tiles and parallel consistency",
     [], [], ("supported",
              "measured by the project's own harnesses (tests/run_tests.py, "
              "tests/run_tiles.py), not by this corpus"), ""),
    ("C55", "output", "Depth/work/storage limits and safe rejection",
     [], [], ("supported",
              "measured by the project's adversarial harness "
              "(tests/run_adversarial.py), not by this corpus"), ""),
]

# One line per demo file, saying what it exercises. A new tests/svg/*.svg file
# without a line here fails the build on purpose: an undescribed demo is worse
# than a missing one.
DEMO_NOTES = {
    "01_triangle.svg": "The smallest useful case: one filled polygon.",
    "02_rect_circle.svg": "Basic shapes — rect and circle — with solid fills.",
    "03_curves.svg": "Cubic and quadratic path segments, smooth continuations.",
    "04_stroke.svg": "Stroke widths, caps and joins on open and closed paths.",
    "05_transform.svg": "translate / rotate / scale on nested groups.",
    "06_evenodd.svg": "The even-odd fill rule against the nonzero default.",
    "07_opacity.svg": "Element and group opacity composited after the group is drawn.",
    "08_group_inherit.svg": "Painting properties inherited down a group tree.",
    "09_viewbox.svg": "viewBox scaling with a non-square aspect ratio.",
    "10_polygon_star.svg": "A self-intersecting star: winding rules on one polygon.",
    "11_style_attr.svg": "Presentation properties given in a style attribute.",
    "12_badge.svg": "A realistic badge: rounded rect, gradient, text.",
    "13_gear_evenodd.svg": "A gear outline with even-odd holes.",
    "14_flower_transforms.svg": "Many rotated copies of one petal: transform stacking.",
    "15_spiral_stroke.svg": "A long stroked spiral path: joins along tight curvature.",
    "16_stress_2000.svg": "Two thousand small shapes: throughput, not features.",
    "17_koch_snowflake.svg": "A deep Koch snowflake: thousands of short line segments.",
    "18_rose_lissajous.svg": "Parametric rose and Lissajous curves as polylines.",
    "19_sierpinski.svg": "Sierpinski triangles: many small filled polygons.",
    "20_function_plot.svg": "Axes, ticks, a plotted curve and labels.",
    "21_hairlines.svg": "Sub-pixel stroke widths: the hairline path in the rasteriser.",
    "22_arcs.svg": "Elliptical arc commands, including large-arc and sweep flags.",
    "23_dashes.svg": "Dash arrays and dash offsets on curves and lines.",
    "24_gradients.svg": "Linear and radial gradients with stops and transforms.",
    "25_text.svg": "Text with the embedded Noto Sans faces: sizes, weights, anchors.",
    "26_layers.svg": "Stacked translucent layers: compositing order.",
    "27_clip.svg": "clipPath applied to a group.",
}

# Third-party material, re-derived from what the code and the harnesses
# actually use rather than from NOTICE. (what, licence, how it is used here)
THIRD_PARTY = [
    ("lean-svg (this project)", "Apache-2.0",
     "The renderer, the harnesses and this site's generator. "
     '<a href="licenses/LICENSE.txt">licence text</a>.'),
    ("resvg 0.48.1 &amp; usvg 0.48.1 — linebender/resvg", "Apache-2.0 OR MIT",
     "resvg is the rendering oracle: every reference image on this site was produced "
     "by <code>resvg --skip-system-fonts --use-fonts-dir &lt;suite&gt;/fonts</code>, and the "
     "semantics of this renderer were matched by reading resvg and usvg. No resvg or "
     "usvg source code is included. "
     '<a href="licenses/resvg-LICENSE-APACHE.txt">Apache-2.0</a>, '
     '<a href="licenses/resvg-LICENSE-MIT.txt">MIT</a>.'),
    ("resvg test suite (crates/resvg/tests/tests) — linebender/resvg", "Apache-2.0 OR MIT",
     "Every SVG in the gallery is republished here <strong>unmodified</strong> so your "
     "browser can render the original file. Same licence as resvg itself: the files live "
     "in that repository. "
     '<a href="licenses/resvg-LICENSE-APACHE.txt">Apache-2.0</a>, '
     '<a href="licenses/resvg-LICENSE-MIT.txt">MIT</a>.'),
    ("resvg test-suite fonts", "SIL OFL 1.1, Apache-2.0, MIT (per face)",
     "Pinned as the oracle's only font set when the reference images were rendered, so "
     "text is compared against known faces. The font files are <strong>not</strong> "
     "republished here. Amiri, M PLUS 1p, Noto (Sans, Serif, Mono, Devanagari, Malayalam, "
     "Znamenny), Roboto Flex, Sedgwick Ave Display, Source Sans Pro: SIL OFL 1.1. "
     "CFF-and-SBIX, Noto Color Emoji (CBDT), Yellowtail: Apache-2.0. "
     "Twitter Color Emoji: MIT."),
    ("tiny-skia — linebender/tiny-skia", "BSD-3-Clause",
     "The anti-aliased scan converter, hairline stroking, curve subdivision counts, dash "
     "splitting, lowp blend arithmetic and gradient evaluation in this renderer are "
     "fixed-point Lean re-implementations of tiny-skia's algorithms. tiny-skia is itself "
     "a port of parts of Skia, Copyright (c) 2011 Google Inc., BSD-3-Clause."),
    ("simplecss — linebender/simplecss", "Apache-2.0 OR MIT",
     "The supported CSS selector subset follows its grammar."),
    ("svgtypes — linebender/svgtypes", "Apache-2.0 OR MIT",
     "Colour, length and transform parsing rules follow its behaviour."),
    ("Noto Sans (Regular, Bold, Italic; Latin subsets)", "SIL OFL 1.1",
     "Compiled into the binary as the renderer's only faces — it loads no font from disk. "
     '<a href="licenses/LICENSE-OFL.txt">licence text</a>.'),
    ("Lean 4 and Lake — leanprover/lean4", "Apache-2.0",
     "The language, compiler and build tool. The renderer has no other dependency."),
    ("NumPy", "BSD-3-Clause",
     "Used by the harnesses and by this generator to score and diff images. Not shipped "
     "in the site."),
    ("Pillow", "MIT-CMU",
     "Used by the harnesses and by this generator to read and write PNGs. Not shipped "
     "in the site."),
    ("fontTools", "MIT",
     "Used offline to subset Noto Sans into the Lean modules the binary embeds, and by "
     "the font checks. Not shipped in the site."),
    ("lean-zip — kim-em/lean-zip", "Apache-2.0",
     "Prior art: the “one input, one output, proven effect boundary” shape of this "
     "project follows its example. No code is shared."),
    ("actions/checkout, actions/cache, actions/upload-pages-artifact, actions/deploy-pages",
     "MIT",
     "Build and publish this site in GitHub Actions."),
]


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------


def render(template, mapping):
    """{{key}} substitution. Deliberately not str % or str.format: the
    templates are full of CSS braces and JS percent signs."""
    out = template
    for key, value in mapping.items():
        out = out.replace("{{%s}}" % key, str(value))
    left = re.search(r"\{\{(\w+)\}\}", out)
    assert left is None, "template placeholder %s was never filled" % left.group(0)
    return out


def esc(text):
    return (str(text).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def resolve_bin(arg):
    """The renderer binary. Survives the microsvg -> lean-svg rename: the
    executable names come from lakefile.toml, with both spellings as a
    fallback."""
    if arg:
        path = Path(arg).expanduser().resolve()
        assert path.is_file(), "no renderer binary at %s" % path
        return path
    names = []
    lakefile = (REPO / "lakefile.toml").read_text(encoding="utf-8")
    for block in lakefile.split("[[lean_exe]]")[1:]:
        match = re.search(r'name\s*=\s*"([^"]+)"', block)
        if match and match.group(1) != "fontdump":
            names.append(match.group(1))
    names += ["lean-svg", "microsvg"]
    bindir = REPO / ".lake" / "build" / "bin"
    for name in names:
        candidate = bindir / name
        if candidate.is_file():
            return candidate
    raise AssertionError(
        "no renderer binary in %s (looked for %s); run `lake build` first"
        % (bindir, ", ".join(dict.fromkeys(names)))
    )


def git_commit():
    out = subprocess.run(
        ["git", "-C", str(REPO), "log", "-1", "--format=%H"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    ).stdout.decode().strip()
    return out or "unknown"


def dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            fp = Path(root) / name
            if fp.is_file():
                total += fp.stat().st_size
    return total


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0


# --------------------------------------------------------------------------
# step 1: the single harness run
# --------------------------------------------------------------------------


def run_harness(work, binary, width, jobs, reuse):
    run_dir = work / "run"
    renders = work / "renders"
    csv_path = run_dir / ("%s_%s.csv" % (CORPUS, ROUTE))
    if reuse and csv_path.is_file() and renders.is_dir():
        print("-- --reuse: keeping %s" % csv_path)
        return run_dir, renders, None
    cmd = [
        sys.executable, str(REPO / "tests" / "run_corpora.py"),
        "--corpus", CORPUS, "--route", ROUTE,
        "--width", str(width), "--jobs", str(jobs), "--no-worst",
        "--keep-renders", str(renders), "--out", str(run_dir),
        "--bin", str(binary),
    ]
    print("-- %s" % " ".join(cmd), flush=True)
    start = time.perf_counter()
    subprocess.run(cmd, check=True)
    return run_dir, renders, time.perf_counter() - start


def read_rows(run_dir):
    csv_path = run_dir / ("%s_%s.csv" % (CORPUS, ROUTE))
    with csv_path.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    assert rows, "the harness produced no rows in %s" % csv_path
    return rows


# --------------------------------------------------------------------------
# step 2: images
# --------------------------------------------------------------------------


def save_small(img, path, colors):
    """Palette-quantise an RGBA image and write it. FASTOCTREE keeps alpha,
    which the checkerboard behind each thumbnail relies on."""
    path.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGBA").quantize(colors=colors, method=Image.FASTOCTREE).save(
        path, optimize=True
    )


def scaled(img, width):
    if img.width <= width:
        return img
    height = max(1, round(img.height * width / img.width))
    return img.resize((width, height), Image.LANCZOS)


def build_card_images(job):
    """One corpus file: three thumbnails, and the same three full size when the
    file is not passing (only those get a click-through)."""
    rel, passing, renders, thumb_dir, full_dir, thumb_w = job
    base = renders / CORPUS / ROUTE / rel
    ref_png = Path(str(base) + ".ref.png")
    ours_png = Path(str(base) + ".ours.png")
    have = {"o": 0, "r": 0, "d": 0}

    for key, src in (("o", ours_png), ("r", ref_png)):
        if not src.is_file():
            continue
        with Image.open(src) as im:
            im = im.convert("RGBA")
            save_small(scaled(im, thumb_w), thumb_dir / (rel + ".%s.png" % key), THUMB_COLORS)
            if not passing:
                save_small(im, full_dir / (rel + ".%s.png" % key), FULL_COLORS)
        have[key] = 1

    panel = diff_image(ref_png, ours_png, DIFF_GAIN) if have["o"] and have["r"] else None
    if panel is not None:
        im = Image.fromarray(panel, "RGB")
        save_small(scaled(im, thumb_w), thumb_dir / (rel + ".d.png"), THUMB_COLORS)
        if not passing:
            save_small(im, full_dir / (rel + ".d.png"), FULL_COLORS)
        have["d"] = 1
    return rel, have


def build_gallery_images(rows, renders, out, thumb_w, jobs):
    thumb_dir = out / "img" / "suite"
    full_dir = out / "img" / "suite-full"
    work = [
        (r["file"], r["status"] == "pass", renders, thumb_dir, full_dir, thumb_w)
        for r in rows
    ]
    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        have = dict(pool.map(build_card_images, work))
    return have, time.perf_counter() - start


def copy_suite_svgs(rows, out):
    """The browser column renders the original file, so the suite's SVGs are
    republished — unmodified, byte for byte."""
    dest_root = out / "svg" / "suite"
    n = 0
    for row in rows:
        src = SUITE_ROOT / row["file"]
        dest = dest_root / row["file"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)
        assert dest.stat().st_size == src.stat().st_size
        n += 1
    return n


# --------------------------------------------------------------------------
# step 3: the demos (our own tests/svg files, at their own width)
# --------------------------------------------------------------------------


def render_demo(job):
    svg, binary, width, out, resvg_args = job
    name = svg.name
    tmp = out / "_tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    ours_png = tmp / (name + ".ours.png")
    ref_png = tmp / (name + ".ref.png")

    ref = subprocess.run(
        ["resvg"] + resvg_args + ["-w", str(width), str(svg), str(ref_png)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    ours = subprocess.run(
        [str(binary), str(svg), str(ours_png), "--width", str(width)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    rec = {
        "f": name,
        "note": DEMO_NOTES[name],
        "rc": ours.returncode,
        "err": ours.stderr.decode("utf-8", "replace").strip().splitlines()[:1],
        "w": 0, "e": None, "within": None, "o": 0, "r": 0, "d": 0,
    }
    rec["err"] = rec["err"][0] if rec["err"] else ""
    assert ref.returncode == 0, "resvg failed on the project's own %s: %s" % (
        name, ref.stderr.decode("utf-8", "replace").strip()
    )

    img_dir = out / "img" / "demo"
    for key, src in (("o", ours_png), ("r", ref_png)):
        if src.is_file():
            with Image.open(src) as im:
                save_small(im.convert("RGBA"), img_dir / (name + ".%s.png" % key), FULL_COLORS)
            rec[key] = 1

    ref_arr = load_rgba(ref_png)
    ours_arr = load_rgba(ours_png)
    if ref_arr is not None and ours_arr is not None and ref_arr.shape == ours_arr.shape:
        metrics, _ = compare(ref_arr, ours_arr, 8)
        rec["e"] = round(metrics["exact"] * 100.0, 3)
        rec["within"] = round(metrics["within"] * 100.0, 3)
        rec["size"] = "%dx%d" % (ref_arr.shape[1], ref_arr.shape[0])
        panel = diff_image(ref_png, ours_png, DIFF_GAIN)
        if panel is not None:
            save_small(Image.fromarray(panel, "RGB"), img_dir / (name + ".d.png"), FULL_COLORS)
            rec["d"] = 1
    for stale in (ours_png, ref_png):
        stale.unlink(missing_ok=True)
    return rec


def build_demos(binary, width, out, jobs, resvg_args):
    svgs = sorted(DEMO_DIR.glob("*.svg"))
    assert svgs, "no demo SVGs in %s" % DEMO_DIR
    missing = [p.name for p in svgs if p.name not in DEMO_NOTES]
    assert not missing, (
        "add a one-line description to DEMO_NOTES in site/gen_site.py for: %s"
        % ", ".join(missing)
    )
    dest = out / "svg" / "demo"
    dest.mkdir(parents=True, exist_ok=True)
    for svg in svgs:
        shutil.copyfile(svg, dest / svg.name)
    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        recs = list(pool.map(
            render_demo, [(s, binary, width, out, resvg_args) for s in svgs]
        ))
    shutil.rmtree(out / "_tmp", ignore_errors=True)
    return recs, time.perf_counter() - start


# --------------------------------------------------------------------------
# step 4: aggregation
# --------------------------------------------------------------------------


def dir_stats(rows):
    """{directory: (pass, files)} for every directory and every top level."""
    stats = {}
    for row in rows:
        top = row["dir"].split("/")[0]
        for key in {row["dir"], top}:
            p, n = stats.get(key, (0, 0))
            stats[key] = (p + (row["status"] == "pass"), n + 1)
    return stats


def feature_rows(rows):
    """One record per audit row: measured pass rate, derived status."""
    by_dir = {}
    for row in rows:
        by_dir.setdefault(row["dir"], []).append(row)

    out = []
    for fid, section, name, dirs, matches, override, note in FEATURES:
        keep = [m for m in matches if not m.startswith("!")]
        drop = [m[1:] for m in matches if m.startswith("!")]
        selected = {}
        for d, drows in by_dir.items():
            if any(d == p or d.startswith(p + "/") for p in dirs):
                for r in drows:
                    selected[r["file"]] = r
        for row in rows:
            if any(m in row["file"] for m in keep):
                selected[row["file"]] = row
        for path in [f for f in selected if any(m in f for m in drop)]:
            del selected[path]
        files = list(selected.values())
        passed = sum(1 for r in files if r["status"] == "pass")
        rate = (passed / len(files)) if files else None

        if override is not None:
            status, why = override
        else:
            assert files, (
                "%s selects no corpus file and has no override in FEATURES" % fid
            )
            status = ("supported" if rate >= SUPPORTED_AT
                      else "partial" if rate >= PARTIAL_AT else "not yet")
            why = ""
        out.append({
            "id": fid, "section": section, "name": name, "dirs": dirs,
            "matches": matches, "files": len(files), "pass": passed,
            "rate": rate, "status": status, "why": why, "note": note,
        })
    return out


# --------------------------------------------------------------------------
# step 5: pages
# --------------------------------------------------------------------------


NAV = [
    ("index.html", "Features"),
    ("gallery.html", "Gallery"),
    ("demos.html", "Demos"),
    ("draw.html", "Draw"),
    ("licensing.html", "Licensing"),
]

REPO_URL = "https://github.com/rowancallahan/lean-svg"


def shell(tpl, page, title, body, mapping):
    nav = "\n".join(
        '<a class="%s" href="%s">%s</a>' % ("on" if href == page else "", href, label)
        for href, label in NAV
    )
    base = dict(mapping)
    base.update({"nav": nav, "title": title, "body": body})
    return render(tpl, base)


def features_page(features, stats, totals, args, meta):
    parts = []
    parts.append(
        '<section class="lede"><h1>lean-svg</h1>'
        "<p>An SVG-to-PNG renderer written in Lean 4, built safety first. "
        "It reads <strong>one</strong> input file and writes <strong>one</strong> output "
        "file, and the effect boundary is proven: no other file is touched, no network, "
        "no shell. Every function is total (no <code>partial</code>, no "
        "<code>unsafe</code>, no <code>panic!</code>), every loop is bounded by the input "
        "size or a constant, and there is no <code>Float</code> anywhere — all geometry "
        "and blending is fixed point.</p>"
        "<p>Fidelity is measured against "
        '<a href="https://github.com/linebender/resvg">resvg 0.48.1</a> as an oracle. '
        "A file <em>passes</em> when at least 99% of its pixels are within 8 levels of "
        "resvg's own rendering of it (max absolute channel difference), which is the same "
        "metric <code>tests/run_tests.py</code> uses.</p></section>"
    )
    parts.append(
        '<section class="headline"><div class="big">%s</div>'
        "<div class=\"cap\">of the %d files in the resvg test suite pass, rendered "
        "directly by lean-svg at %d px wide</div></section>"
        % ("%.1f%%" % (totals["rate"] * 100.0), totals["files"], args.width)
    )

    top_rows = []
    for top in sorted({k for k in stats if "/" not in k}):
        p, n = stats[top]
        top_rows.append(
            '<tr><td><a href="gallery.html#dirs=%s">%s</a></td><td>%d</td><td>%d</td>'
            '<td class="num">%.1f%%</td><td class="bar"><span style="width:%.1f%%"></span></td></tr>'
            % (top, top, n, p, p / n * 100.0, p / n * 100.0)
        )
    parts.append(
        "<section><h2>By top-level directory</h2>"
        '<table class="grid"><thead><tr><th>directory</th><th>files</th><th>pass</th>'
        "<th>pass rate</th><th></th></tr></thead><tbody>%s</tbody></table>"
        "</section>" % "\n".join(top_rows)
    )

    parts.append(
        "<section><h2>Feature audit</h2>"
        "<p>The C01–C55 rows from <code>PLAN.md</code>. A row's status is derived from the "
        "pass rate of the corpus directories that measure it in this same run: "
        "<strong>supported</strong> at %d%% or more, <strong>partial</strong> at %d%% or "
        "more, <strong>not yet</strong> below that. Rows this corpus cannot measure carry "
        "an explicit status and the reason. Directories are shared between rows, so the "
        "file counts must not be summed.</p>" % (SUPPORTED_AT * 100, PARTIAL_AT * 100)
    )
    for key, label in SECTIONS:
        parts.append("<h3>%s</h3>" % esc(label))
        parts.append(
            '<table class="grid features"><thead><tr><th>ID</th><th>feature</th>'
            "<th>status</th><th>measured</th><th>files</th><th>corpus</th></tr></thead><tbody>"
        )
        for f in [f for f in features if f["section"] == key]:
            slug = f["status"].replace(" ", "-")
            measured = "—" if f["rate"] is None else "%.1f%%" % (f["rate"] * 100.0)
            counts = "—" if not f["files"] else "%d / %d" % (f["pass"], f["files"])
            selectors = f["dirs"] + f["matches"]
            if selectors:
                link = ('<a href="gallery.html#dirs=%s">%s</a>'
                        % (",".join(selectors), esc(", ".join(selectors))))
            else:
                link = '<span class="muted">no corpus coverage</span>'
            why = f["why"] or f["note"]
            parts.append(
                "<tr><td>%s</td><td>%s%s</td><td><span class=\"pill %s\">%s</span></td>"
                '<td class="num">%s</td><td class="num">%s</td><td class="dirs">%s</td></tr>'
                % (f["id"], esc(f["name"]),
                   ('<div class="muted">%s</div>' % esc(why)) if why else "",
                   slug, f["status"], measured, counts, link)
            )
        parts.append("</tbody></table>")
    parts.append("</section>")

    parts.append(
        "<section><h2>What this is not</h2><ul>"
        "<li>Filters, markers, patterns, <code>use</code>/<code>symbol</code>, embedded "
        "images and text along paths are <em>not</em> implemented; their fixtures are in "
        "the gallery and they show what they show.</li>"
        "<li>External references (images, CSS, fonts) are refused on purpose. That "
        "rejection counts against the pass rate above, and it is not counted separately "
        "or excused.</li>"
        "<li>The numbers here are one run at one width (%d px). Pass/fail flips at the "
        "99%% threshold when the width changes, so numbers from different widths are not "
        "comparable and are never mixed on this site.</li></ul></section>" % args.width
    )
    return "\n".join(parts)


def gallery_page(rows, stats, totals, args, meta):
    dirs = sorted({r["dir"] for r in rows})
    tops = sorted({r["dir"].split("/")[0] for r in rows})
    dir_rows = []
    for top in tops:
        p, n = stats[top]
        dir_rows.append(
            '<tr><td>%s</td><td>%d</td><td>%d</td><td class="num">%.1f%%</td></tr>'
            % (top, n, p, p / n * 100.0)
        )
    return """
<section class="lede">
  <h1>Gallery</h1>
  <p>Every file in the resvg test suite, rendered three ways at {{width}} px wide:
  <strong>lean-svg</strong> (this renderer), <strong>resvg 0.48.1</strong> (the oracle),
  and <strong>your browser</strong> rendering the original file. The fourth panel is the
  difference between lean-svg and resvg, amplified {{gain}}&times;.</p>
  <p class="warn">The browser column is whatever engine you are reading this in
  (Blink, WebKit or Gecko) — it is a sanity check, not a reference, and nothing on this
  site is ever scored against it. Scores compare lean-svg against resvg only.</p>
  <p class="muted">The SVG files are from
  <a href="https://github.com/linebender/resvg">linebender/resvg</a>
  (<code>crates/resvg/tests/tests</code>), republished here unmodified under
  Apache-2.0 OR MIT so your browser has the original to render. See
  <a href="licensing.html">Licensing</a>.</p>
</section>
<section>
  <table class="grid compact"><thead><tr><th>directory</th><th>files</th><th>pass</th>
  <th>pass rate</th></tr></thead><tbody>{{dirrows}}
  <tr class="tot"><td>total</td><td>{{files}}</td><td>{{passed}}</td>
  <td class="num">{{rate}}</td></tr></tbody></table>
</section>
<div class="controls">
  <label>directory <select id="topFilter"></select></label>
  <label>subdirectory <select id="subFilter"></select></label>
  <label>status <select id="statusFilter">
    <option value="">(all)</option>
    <option value="pass">pass</option>
    <option value="fail">fail</option>
    <option value="unsupported">rejected by lean-svg</option>
    <option value="error">error</option>
    <option value="size-mismatch">size mismatch</option>
  </select></label>
  <label>sort <select id="sortSelect">
    <option value="worst">worst first</option>
    <option value="path">path</option>
  </select></label>
  <input id="searchBox" type="search" placeholder="search path">
  <button id="resetBtn" type="button">reset</button>
  <span id="countLabel"></span>
</div>
<div id="cards" class="cards"></div>
<button id="moreBtn" class="more" type="button" hidden>show more</button>
<div class="overlay hidden" id="overlay" role="dialog" aria-modal="true">
  <button class="overlay-close" id="overlayClose" aria-label="close">&times;</button>
  <div class="overlay-inner">
    <h3 id="ovTitle"></h3>
    <div class="ovimgs">
      <figure><div class="stage"><img id="ovOurs" alt="lean-svg rendering"></div>
        <figcaption>lean-svg</figcaption></figure>
      <figure><div class="stage"><img id="ovRef" alt="resvg rendering"></div>
        <figcaption>resvg 0.48.1</figcaption></figure>
      <figure><div class="stage"><img id="ovBrowser" alt="your browser's rendering"></div>
        <figcaption>your browser</figcaption></figure>
      <figure><div class="stage"><img id="ovDiff" alt="difference"></div>
        <figcaption>diff &times;{{gain}}</figcaption></figure>
    </div>
    <p id="ovMeta" class="mono"></p>
    <p><a id="ovSrc" href="#" target="_blank" rel="noopener">SVG source</a></p>
  </div>
</div>
""".replace("{{width}}", str(args.width)).replace("{{gain}}", str(DIFF_GAIN)) \
   .replace("{{dirrows}}", "\n".join(dir_rows)) \
   .replace("{{files}}", str(totals["files"])) \
   .replace("{{passed}}", str(totals["pass"])) \
   .replace("{{rate}}", "%.1f%%" % (totals["rate"] * 100.0))


def demos_page(recs, args):
    cards = []
    for rec in recs:
        name = rec["f"]
        enc = urlpath(name)
        metrics = (
            '<span class="mono">within-8 %s%% &middot; exact %s%% &middot; %s</span>'
            % (rec["within"], rec["e"], rec.get("size", "-"))
            if rec["within"] is not None else
            '<span class="mono bad">rc=%s %s</span>' % (rec["rc"], esc(rec["err"]))
        )
        img = lambda key, alt: (  # noqa: E731
            '<div class="stage"><img loading="lazy" src="img/demo/%s.%s.png" alt="%s"></div>'
            % (enc, key, alt) if rec[key] else '<div class="stage empty">n/a</div>'
        )
        cards.append(
            '<article class="democard">'
            "<h3>%s</h3><p class=\"note\">%s</p>"
            '<div class="cols four">'
            "<figure>%s<figcaption>lean-svg</figcaption></figure>"
            "<figure>%s<figcaption>resvg 0.48.1</figcaption></figure>"
            '<figure><div class="stage"><img loading="lazy" src="svg/demo/%s" alt="browser rendering"></div>'
            "<figcaption>your browser</figcaption></figure>"
            "<figure>%s<figcaption>diff &times;%d</figcaption></figure>"
            "</div><p class=\"metrics\">%s &middot; "
            '<a href="svg/demo/%s" target="_blank" rel="noopener">SVG source</a></p></article>'
            % (esc(name), esc(rec["note"]), img("o", "lean-svg rendering"),
               img("r", "resvg rendering"), enc, img("d", "difference"), DIFF_GAIN,
               metrics, enc)
        )
    return (
        '<section class="lede"><h1>Demos</h1>'
        "<p>The project's own test images, rendered at %d px wide by lean-svg, by resvg "
        "0.48.1 and by your browser, with the lean-svg/resvg difference amplified %d&times;. "
        "These are our files, not the suite's: they exercise the features this renderer "
        "actually implements.</p>"
        '<p class="warn">The browser column is your engine, not a reference. The '
        "percentages compare lean-svg against resvg only. They are rendered at %d px here, "
        "so they are not comparable with the %d px corpus numbers on the other pages.</p>"
        "</section><div class=\"demos\">%s</div>"
        % (args.demo_width, DIFF_GAIN, args.demo_width, args.width, "\n".join(cards))
    )


def licensing_page():
    rows = "\n".join(
        "<tr><td>%s</td><td><code>%s</code></td><td>%s</td></tr>" % (what, lic, how)
        for what, lic, how in THIRD_PARTY
    )
    return """
<section class="lede">
  <h1>Licensing</h1>
  <p>Everything third-party that this project or this site touches, what it is used for,
  and its licence. lean-svg itself is Apache-2.0.</p>
</section>
<section>
  <table class="grid licensing"><thead><tr><th>what</th><th>licence</th>
  <th>how it is used here</th></tr></thead><tbody>{{rows}}</tbody></table>
</section>
<section>
  <h2>Republished files</h2>
  <p>The gallery republishes the SVG files from
  <code>crates/resvg/tests/tests</code> in
  <a href="https://github.com/linebender/resvg">linebender/resvg</a> 0.48.1, byte for byte
  and <strong>unmodified</strong>, so your browser can render the original file next to
  ours. They are licensed <code>Apache-2.0 OR MIT</code>
  (<a href="licenses/resvg-LICENSE-APACHE.txt">Apache-2.0</a>,
  <a href="licenses/resvg-LICENSE-MIT.txt">MIT</a>); copies of both licence texts ship
  with this site. resvg was relicensed from MPL-2.0 to <code>Apache-2.0 OR MIT</code> in
  0.45.0, so the MPL no longer applies to the version used here.</p>
  <p>The PNG renderings on this site are generated: ours by lean-svg, the reference ones
  by resvg 0.48.1 from those same files. The suite's font files are not republished.</p>
</section>
<section>
  <h2>Licence texts shipped with this site</h2>
  <ul>
    <li><a href="licenses/LICENSE.txt">lean-svg — Apache-2.0</a></li>
    <li><a href="licenses/NOTICE.txt">lean-svg NOTICE</a></li>
    <li><a href="licenses/resvg-LICENSE-APACHE.txt">resvg and its test suite — Apache-2.0</a></li>
    <li><a href="licenses/resvg-LICENSE-MIT.txt">resvg and its test suite — MIT</a></li>
    <li><a href="licenses/LICENSE-OFL.txt">Noto Sans — SIL Open Font License 1.1</a></li>
  </ul>
</section>
""".replace("{{rows}}", rows)


def draw_page():
    return """
<section class="lede">
  <h1>Draw</h1>
  <p>Draw shapes on the canvas; the SVG source appears beside it and your browser renders
  it live. Edit the source directly and the drawing follows.</p>
</section>
<div class="draw">
  <div class="panel">
    <div class="row">
      <button class="mode on" data-mode="polygon" type="button">polygon</button>
      <button class="mode" data-mode="freehand" type="button">freehand</button>
      <button class="mode" data-mode="circle" type="button">circle</button>
      <button class="mode" data-mode="rect" type="button">rect</button>
      <button class="mode" data-mode="line" type="button">line</button>
    </div>
    <canvas id="drawCanvas" width="240" height="240"></canvas>
    <p class="hint" id="drawHint"></p>
    <div class="row">
      <label><input type="color" id="fill" value="#e63946"> fill</label>
      <label><input type="checkbox" id="noFill"> none</label>
      <label><input type="color" id="stroke" value="#1d3557"> stroke</label>
      <label><input type="number" id="strokeWidth" value="0" min="0" max="50" step="1"> width</label>
    </div>
    <div class="row">
      <button id="closeShape" type="button">close shape</button>
      <button id="undo" type="button">undo</button>
      <button id="clearDraw" type="button">clear</button>
      <button id="download" type="button">download .svg</button>
    </div>
  </div>
  <div class="panel">
    <h2>SVG source</h2>
    <textarea id="src" rows="16" spellcheck="false" aria-label="SVG source"></textarea>
    <h2>Your browser's rendering</h2>
    <div class="stage" id="preview"></div>
  </div>
</div>
"""


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--out", default=str(SITE / "_build"), help="output directory")
    ap.add_argument("--bin", default=None,
                    help="renderer binary (default: from lakefile.toml, in .lake/build/bin)")
    ap.add_argument("--width", type=int, default=200,
                    help="render width for the whole corpus run (default 200). Every "
                         "number on the site comes from this one width")
    ap.add_argument("--demo-width", type=int, default=480,
                    help="render width for the demos page (default 480)")
    ap.add_argument("--thumb", type=int, default=150, help="thumbnail width (default 150)")
    ap.add_argument("--jobs", type=int, default=None, help="workers (default hw.ncpu)")
    ap.add_argument("--reuse", action="store_true",
                    help="reuse an existing harness run under <out>/_work")
    args = ap.parse_args()

    jobs = args.jobs or (os.cpu_count() or 4)
    binary = resolve_bin(args.bin)
    assert shutil.which("resvg"), "resvg not on PATH (the oracle for every reference image)"
    assert SUITE_ROOT.is_dir(), "resvg test suite not found at %s" % SUITE_ROOT

    out = Path(args.out).expanduser().resolve()
    work = out / "_work"
    for stale in ("index.html", "gallery.html", "demos.html", "draw.html", "licensing.html"):
        (out / stale).unlink(missing_ok=True)
    for stale in ("img", "svg", "assets", "data", "licenses"):
        shutil.rmtree(out / stale, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)

    grand = time.perf_counter()
    run_dir, renders, harness_s = run_harness(work, binary, args.width, jobs, args.reuse)
    rows = read_rows(run_dir)
    for row in rows:
        assert int(row["width"]) == args.width, (
            "row %s was rendered at %s px, not %s: refusing to mix widths"
            % (row["file"], row["width"], args.width)
        )

    have, img_s = build_gallery_images(rows, renders, out, args.thumb, jobs)
    n_svg = copy_suite_svgs(rows, out)
    demos, demo_s = build_demos(
        binary, args.demo_width, out, jobs, resvg_font_args(False)
    )

    stats = dir_stats(rows)
    passed = sum(1 for r in rows if r["status"] == "pass")
    totals = {"files": len(rows), "pass": passed, "rate": passed / len(rows)}
    features = feature_rows(rows)

    # ---- data files
    (out / "data").mkdir(parents=True, exist_ok=True)
    cards = []
    for row in rows:
        h = have[row["file"]]
        cards.append({
            "f": row["file"],
            "t": row["dir"].split("/")[0],
            "d": row["dir"],
            "s": row["status"],
            "g": STATUS_GROUP.get(row["status"], "error"),
            "w": None if row["within"] == "" else round(float(row["within"]) * 100.0, 3),
            "e": None if row["exact"] == "" else round(float(row["exact"]) * 100.0, 3),
            "z": row["size"],
            "rc": row["ours_rc"],
            "err": row["ours_err"] or row["ref_err"],
            "o": h["o"], "r": h["r"], "df": h["d"],
            "x": 0 if row["status"] == "pass" else 1,
        })
    # The page may never quietly show fewer files than the run measured.
    csv_counts = Counter(r["status"] for r in rows)
    card_counts = Counter(c["s"] for c in cards)
    assert len(cards) == len(rows), "%d cards for %d CSV rows" % (len(cards), len(rows))
    assert card_counts == csv_counts, "card statuses %s != CSV statuses %s" % (
        dict(card_counts), dict(csv_counts)
    )
    (out / "data" / "gallery.json").write_text(
        json.dumps(cards, separators=(",", ":")), encoding="utf-8"
    )

    # ---- static assets
    shutil.copytree(SITE / "assets", out / "assets")

    # ---- licence texts
    lic = out / "licenses"
    lic.mkdir(parents=True, exist_ok=True)
    suite_repo = SUITE_ROOT.resolve()
    while suite_repo != suite_repo.parent and not (suite_repo / "LICENSE-APACHE").is_file():
        suite_repo = suite_repo.parent
    assert (suite_repo / "LICENSE-APACHE").is_file(), (
        "no LICENSE-APACHE above %s: the suite checkout must carry resvg's licences"
        % SUITE_ROOT
    )
    shutil.copyfile(suite_repo / "LICENSE-APACHE", lic / "resvg-LICENSE-APACHE.txt")
    shutil.copyfile(suite_repo / "LICENSE-MIT", lic / "resvg-LICENSE-MIT.txt")
    shutil.copyfile(REPO / "LICENSE", lic / "LICENSE.txt")
    shutil.copyfile(REPO / "NOTICE", lic / "NOTICE.txt")
    fonts_license = next(REPO.glob("*/Fonts/LICENSE-OFL.txt"))
    shutil.copyfile(fonts_license, lic / "LICENSE-OFL.txt")

    # ---- pages
    tpl = (SITE / "templates" / "shell.html").read_text(encoding="utf-8")
    commit = git_commit()
    meta = {
        "generated": time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime()),
        "commit": commit,
        "commit_short": commit[:9],
        "repo": REPO_URL,
        "resvg": subprocess.run(["resvg", "--version"], stdout=subprocess.PIPE)
                 .stdout.decode().strip(),
        "headline": "%.1f%%" % (totals["rate"] * 100.0),
        "files": str(totals["files"]),
        "passed": str(totals["pass"]),
        "width": str(args.width),
    }
    pages = [
        ("index.html", "Features", features_page(features, stats, totals, args, meta), ""),
        ("gallery.html", "Gallery", gallery_page(rows, stats, totals, args, meta),
         '<script src="assets/gallery.js"></script>'),
        ("demos.html", "Demos", demos_page(demos, args), ""),
        ("draw.html", "Draw", draw_page(), '<script src="assets/draw.js"></script>'),
        ("licensing.html", "Licensing", licensing_page(), ""),
    ]
    for name, title, body, scripts in pages:
        mapping = dict(meta)
        mapping["scripts"] = scripts
        (out / name).write_text(
            shell(tpl, name, title, body, mapping), encoding="utf-8"
        )
    (out / ".nojekyll").write_text("", encoding="utf-8")

    # ---- report
    total_bytes = dir_size(out) - dir_size(work)
    breakdown = [
        ("thumbnails (img/suite)", dir_size(out / "img" / "suite")),
        ("click-through images (img/suite-full)", dir_size(out / "img" / "suite-full")),
        ("demo images (img/demo)", dir_size(out / "img" / "demo")),
        ("republished suite SVGs", dir_size(out / "svg" / "suite")),
        ("demo SVGs", dir_size(out / "svg" / "demo")),
        ("data + pages + assets + licences",
         total_bytes - dir_size(out / "img") - dir_size(out / "svg")),
    ]
    print("\n== site built in %s" % out)
    print("corpus: %d files, %d pass (%.1f%%) at width %d, direct route only"
          % (totals["files"], totals["pass"], totals["rate"] * 100.0, args.width))
    print("images: %d cards, %d suite SVGs republished, %d demos"
          % (len(rows), n_svg, len(demos)))
    print("card statuses match the CSV: %s"
          % ", ".join("%s %d" % kv for kv in sorted(card_counts.items())))
    for label, size in breakdown:
        print("  %-40s %10s" % (label, human(size)))
    print("  %-40s %10s" % ("TOTAL (artifact)", human(total_bytes)))
    assert total_bytes < 400 * 1024 * 1024, (
        "artifact is %s, over the 400 MB cap" % human(total_bytes)
    )
    print("timings: harness %s, images %.1fs, demos %.1fs, total %.1fs"
          % ("reused" if harness_s is None else "%.1fs" % harness_s,
             img_s, demo_s, time.perf_counter() - grand))
    return 0


if __name__ == "__main__":
    sys.exit(main())
