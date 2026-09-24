#!/usr/bin/env python3
"""Safety harness: feed hostile inputs to lean-svg and check that it never
crashes, never hangs, and never writes a file other than the requested output.

Inputs are the checked-in corpus in tests/adversarial/ plus a set of generated
cases written fresh into tests/out/adversarial_gen/ on every run.

Each input is rendered into its own fresh temporary directory, and the run is a
VIOLATION unless all of the following hold:
  * the process exits 0, 1 or 2 within the timeout (a signal shows up as a
    negative return code on macOS and is never acceptable);
  * it writes nothing at all to stdout or stderr (T98b);
  * out.png exists if and only if the return code is 0 or 2;
  * the temporary directory contains nothing but out.png;
  * any out.png produced starts with the PNG signature and opens in Pillow.
"""

import argparse
import base64
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SVG_DIR = REPO / "tests" / "svg"
ADV_DIR = REPO / "tests" / "adversarial"
OUT_DIR = REPO / "tests" / "out"
GEN_DIR = OUT_DIR / "adversarial_gen"
DEFAULT_BIN = REPO / ".lake" / "build" / "bin" / "lean-svg"

# T98b: without `--warnings` lean-svg never writes `out.png.warnings.txt`;
# the PNG is the only file it may create.
ALLOWED_OUTPUTS = ("out.png",)
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

    # parser caps nesting depth at 2048 (T104; was 64): 3000 should be
    # rejected, 60 and 2000 accepted, 2000 also under descendant selectors.
    write_text("deep_nesting_3000.svg", nested(3000))
    write_text("deep_nesting_2000.svg", nested(2000))
    write_text("deep_nesting_60.svg", nested(60))
    write_text("deep_nesting_2000_css.svg", nested(2000).replace(
        '<g>', '<style>g g g rect{fill:red} svg g g rect{stroke:blue}</style><g>', 1))

    # --- T86 namespaces -----------------------------------------------------
    # Namespace scopes nest with the elements.  60 levels each binding a
    # fresh prefix stay under Xml.maxNsBindings (64) and render; two per level
    # overflow it and are rejected; the default namespace and a prefix rebound
    # at each of 30 levels (60 bindings), and a deep non-SVG subtree (dropped
    # whole, text included) render.
    ns_head = '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
    rect = '<rect x="10" y="10" width="80" height="80" fill="#3366cc"/>'

    def ns_nested(depth, per):
        opens = "".join(
            "<g %s>" % " ".join(
                'xmlns:p%d_%d="http://example.org/%d/%d"' % (d, k, d, k) for k in range(per))
            for d in range(depth))
        return ns_head + opens + rect + "</g>" * depth + "\n</svg>\n"

    write_text("ns_nested_60.svg", ns_nested(60, 1))
    write_text("ns_nested_overflow.svg", ns_nested(60, 2))
    write_text(
        "ns_rebind_30.svg",
        ns_head
        + '<s:g xmlns:s="http://www.w3.org/2000/svg" xmlns="http://example.org/x">' * 30
        + '<s:rect x="10" y="10" width="80" height="80" fill="#3366cc"/><rect width="100" height="100"/>'
        + "</s:g>" * 30
        + "\n</svg>\n",
    )
    write_text(
        "ns_foreign_deep.svg",
        ns_head
        + '<f:x xmlns:f="http://example.org/f">'
        + "<g>" * 60 + "<text>t</text>" + rect + "</g>" * 60
        + "</f:x>" + rect + "\n</svg>\n",
    )
    # A root with no size is refit to its content's box (usvg
    # calculate_svg_bbox); a huge box must still hit the canvas caps.
    write_text(
        "refit_huge.svg",
        '<svg xmlns="http://www.w3.org/2000/svg">'
        '<rect x="100000" y="100000" width="10" height="10"/></svg>\n',
    )
    write_text("ns_unknown_prefix.svg", ns_head + "<q:rect/>\n</svg>\n")
    # Worst case for prefix lookup: 63 bindings in scope and 10^5 elements
    # whose prefixed attributes resolve through the outermost one.
    binds = " ".join('xmlns:n%d="http://example.org/%d"' % (k, k) for k in range(62))
    write_text(
        "ns_lookup_flood.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        + binds + ' width="100" height="100">\n'
        + '<rect xlink:title="a" xlink:role="b" xlink:arcrole="c" width="1" height="1"/>' * 100_000
        + "\n</svg>\n",
    )

    # --- T22 compositing layers -------------------------------------------
    # Every one of these asks for far more layers than the renderer will
    # allocate; each must be answered with a clean exit, never a crash, a hang
    # or an out-of-memory.

    def nested_layers(depth, head, body):
        return (
            head
            + '<g opacity="0.5">' * depth
            + body
            + "</g>" * depth
            + "\n</svg>\n"
        )

    # 100k nested groups, each asking for its own layer. The XML parser's depth
    # cap (Xml.maxDepth = 64) rejects this long before any layer is allocated.
    write_text(
        "layers_nested_100k.svg",
        nested_layers(
            100_000,
            '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">\n',
            '<rect x="10" y="10" width="180" height="180" fill="#3366cc"/>',
        ),
    )

    # A group opacity on a 16384x16384 canvas: the canvas itself is 268 Mpx,
    # over the 16 Mpx area cap, so this is rejected before a layer is sized.
    write_text(
        "layers_huge_canvas.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="16384" height="16384">\n'
        '<g opacity="0.5"><rect x="0" y="0" width="16384" height="16384" '
        'fill="#3366cc"/></g>\n</svg>\n',
    )

    # Nested full-canvas layers on a canvas that is exactly at the area cap:
    # this is the case that reaches Render.maxLayerPixels (4x maxPixels) and
    # must come back as the "layer budget" error rather than allocating 5
    # canvases of 16 Mpx.
    write_text(
        "layers_budget.svg",
        nested_layers(
            6,
            '<svg xmlns="http://www.w3.org/2000/svg" width="4096" height="4096">\n',
            '<rect x="0" y="0" width="4096" height="4096" fill="#3366cc"/>',
        ),
    )

    # 10 000 sibling layers: bounded depth, unbounded count. Only one layer is
    # live at a time, so this must render rather than hit the budget.
    write_text(
        "layers_siblings_10k.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">\n'
        + "\n".join(
            '<g opacity="0.5" style="mix-blend-mode:multiply">'
            '<rect x="%d" y="%d" width="12" height="12" fill="#204080"/></g>'
            % (i % 190, (i // 190) % 190)
            for i in range(10_000)
        )
        + "\n</svg>\n",
    )

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

    # ---- T18: gradient paint servers ------------------------------------
    head200 = (
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink='
        '"http://www.w3.org/1999/xlink" width="200" height="200" '
        'viewBox="0 0 200 200">\n'
    )
    target = '<rect x="10" y="10" width="180" height="180" fill="url(#g)"/>\n'

    # 100 000 stops in one gradient: the table keeps at most Grad.maxStops.
    stops = "".join(
        '<stop offset="%.6f" stop-color="#%02x%02x40"/>' % (i / 100_000, i % 256, i % 199)
        for i in range(100_000)
    )
    write_text(
        "grad_100k_stops.svg",
        head200 + '<linearGradient id="g">' + stops + "</linearGradient>\n"
        + target + "</svg>\n",
    )

    # 4097 gradients, one past Grad.maxDefs; the shape references the last one,
    # which is therefore not in the table and falls back.
    grads = "".join(
        '<linearGradient id="g%d"><stop offset="0" stop-color="#f00"/>'
        '<stop offset="1" stop-color="#00f"/></linearGradient>' % i
        for i in range(4097)
    )
    write_text(
        "grad_4097_defs.svg",
        head200 + grads + '<rect x="10" y="10" width="180" height="180" '
        'fill="url(#g4096) green"/>\n</svg>\n',
    )

    # `href` pointing at itself, and a pair pointing at each other.
    write_text(
        "grad_href_self_cycle.svg",
        head200
        + '<linearGradient id="g" xlink:href="#g"/>\n'
        '<linearGradient id="h" xlink:href="#i"/>\n'
        '<linearGradient id="i" xlink:href="#h"/>\n'
        + target
        + '<rect x="10" y="10" width="80" height="80" fill="url(#h)"/>\n</svg>\n',
    )

    # a nine-link `href` chain: one longer than Grad.hrefFuel, so the stops at
    # the far end are out of reach.
    chain = "".join(
        '<linearGradient id="c%d" xlink:href="#c%d"/>' % (i, i + 1) for i in range(9)
    )
    write_text(
        "grad_href_chain_9.svg",
        head200 + chain
        + '<linearGradient id="c9"><stop offset="0" stop-color="#f00"/>'
        '<stop offset="1" stop-color="#00f"/></linearGradient>\n'
        '<rect x="10" y="10" width="180" height="180" fill="url(#c0)"/>\n</svg>\n',
    )

    # radii and coordinates at the clamp, with every spread method.
    write_text(
        "grad_huge_radius.svg",
        head200
        + '<radialGradient id="g" gradientUnits="userSpaceOnUse" cx="1e9" cy="-1e9"'
        ' r="1e9" fr="1e8" fx="5e8" spreadMethod="repeat">'
        '<stop offset="0" stop-color="#f00"/><stop offset="1" stop-color="#00f"/>'
        "</radialGradient>\n"
        '<linearGradient id="t" gradientUnits="userSpaceOnUse" x1="0" x2="1e-6"'
        ' spreadMethod="reflect"><stop offset="0" stop-color="#0f0"/>'
        '<stop offset="1" stop-color="#000"/></linearGradient>\n'
        + target
        + '<rect x="20" y="20" width="60" height="60" fill="url(#t)"/>\n</svg>\n',
    )

    # objectBoundingBox gradients on shapes with no area at all.
    write_text(
        "grad_zero_area_shape.svg",
        head200
        + '<linearGradient id="g"><stop offset="0" stop-color="#f00"/>'
        '<stop offset="1" stop-color="#00f"/></linearGradient>\n'
        '<path d="M 20 20 L 180 20" fill="url(#g)" stroke="url(#g)" stroke-width="4"/>\n'
        '<path d="M 20 40 L 20 180" fill="url(#g)"/>\n'
        '<path d="M 60 60 Z" fill="url(#g)"/>\n'
        '<rect x="30" y="30" width="0" height="80" fill="url(#g)"/>\n</svg>\n',
    )

    # ---- T47: use / symbol ----------------------------------------------
    # (the checked-in use_billion_laughs.svg and use_cycle.svg cover the
    # exponential fan-out and the reference cycle usvg's checks miss.)
    use_head = (
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink='
        '"http://www.w3.org/1999/xlink" width="200" height="200">\n'
    )

    def use_chain(n):
        return (
            use_head
            + '<rect id="c0" width="20" height="20" fill="#3366cc"/>\n'
            + "".join(
                '<g id="c%d"><use xlink:href="#c%d" x="1"/></g>\n' % (i, i - 1)
                for i in range(1, n + 1)
            )
            + "</svg>\n"
        )

    # Use.maxDepth (10) nested expansions render; one more is rejected.
    write_text("use_chain_10.svg", use_chain(9))
    write_text("use_chain_11.svg", use_chain(12))

    # 10^5 rects reached through a 10-way fan-out: large but within the
    # element budget, so it must render.
    fan = '<rect id="f0" width="1" height="1" fill="#000"/>\n'
    for i in range(1, 6):
        fan += '<g id="f%d">%s</g>\n' % (
            i,
            "".join('<use xlink:href="#f%d" x="%d"/>' % (i - 1, k) for k in range(10)),
        )
    write_text("use_fanout_1e5.svg", use_head + "<defs>" + fan + "</defs>"
               '<use xlink:href="#f5"/>\n</svg>\n')

    # Every use points at a big group that contains a use back to itself: each
    # one costs a scan of the group and copies nothing.  The work budget
    # rejects this instead of doing 10^9 steps.
    write_text(
        "use_recursion_scan.svg",
        use_head
        + '<g id="big">'
        + '<rect width="1" height="1"/>' * 100_000
        + '<use xlink:href="#big"/></g>\n'
        + '<use xlink:href="#big"/>' * 10_000
        + "\n</svg>\n",
    )

    # 5000 symbol instances, each with a viewport clip: past Svg.maxClipPaths
    # the clip could not be honoured, so the document is rejected.
    write_text(
        "use_symbol_5000.svg",
        use_head
        + '<symbol id="s" viewBox="0 0 10 10"><rect width="20" height="20"/></symbol>\n'
        + "".join(
            '<use xlink:href="#s" x="%d" y="%d" width="2" height="2"/>' % (i % 200, i // 200)
            for i in range(5000)
        )
        + "\n</svg>\n",
    )

    # ---- T63: <image> ---------------------------------------------------
    # A 30 MB data: URI (a PNG signature, then noise): decoded, rejected by
    # the decoder, drawn as nothing.  Well under the 64 MiB input cap.
    noise = random.Random(63).randbytes(22_000_000)
    write_text(
        "image_data_30mb.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\n'
        '<image width="100" height="100" href="data:image/png;base64,'
        + base64.b64encode(b"\x89PNG\r\n\x1a\n" + noise).decode()
        + '"/>\n<rect x="10" y="10" width="20" height="20"/>\n</svg>\n',
    )

    # A decompression bomb: ~65 KB of PNG that inflates to 4096x4096 RGBA
    # (the per-image cap), drawn through 300 `use` copies.  The document-wide
    # pixel budget (Image.maxTotalPixels) keeps two decodes and skips the rest.
    def png_chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    side = 4096
    bomb = (b"\x89PNG\r\n\x1a\n"
            + png_chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + png_chunk(b"IDAT", zlib.compress(b"\x00" * ((side * 4 + 1) * side), 9))
            + png_chunk(b"IEND", b""))
    write_text(
        "image_bomb_uses.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"'
        ' width="100" height="100">\n<defs><image id="b" width="10" height="10" '
        'href="data:image/png;base64,' + base64.b64encode(bomb).decode() + '"/></defs>\n'
        + "".join('<use xlink:href="#b" x="%d" y="%d"/>' % (i % 10 * 10, i // 30 * 10)
                  for i in range(300))
        + "\n</svg>\n",
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

    # ---- T52: marker instancing -------------------------------------------

    # A path with half a million vertices, each with `marker-start`/`-mid`/
    # `-end` pointing at a marker with several children: naively
    # 500_000 x 3 x 10 = 15,000,000 `Node`s, the "10^6 vertices with a heavy
    # marker" case `Marker.maxMarkerNodes` exists to cap.
    marker_zigzag = "".join(
        " L %d %d" % (i % 200, 10 if i % 2 else 190) for i in range(500_000)
    )
    marker_children = "".join(
        '<rect x="0" y="0" width="2" height="2" fill="#%02x%02x%02x"/>'
        % (i * 7 % 256, i * 13 % 256, i * 19 % 256)
        for i in range(10)
    )
    write_text(
        "marker_huge_path.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">\n'
        '<marker id="m" markerWidth="4" markerHeight="4" refX="2" refY="2">'
        + marker_children + "</marker>\n"
        '<path d="M 0 0%s" fill="none" stroke="#000" '
        'marker-start="url(#m)" marker-mid="url(#m)" marker-end="url(#m)"/>\n</svg>\n'
        % marker_zigzag,
    )

    # Two markers whose content each reference the other (never a shape
    # referencing itself directly, so this is only caught by tracking every
    # marker currently being expanded, not just the innermost one).
    write_text(
        "marker_mutual_cycle.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">\n'
        '<marker id="ma" markerWidth="10" markerHeight="10" refX="5" refY="5">'
        '<path d="M 0 0 L 10 10" marker-start="url(#mb)" marker-end="url(#mb)"/></marker>\n'
        '<marker id="mb" markerWidth="10" markerHeight="10" refX="5" refY="5">'
        '<path d="M 0 0 L 10 10" marker-start="url(#ma)" marker-end="url(#ma)"/></marker>\n'
        '<path d="M 10 10 L 190 190" fill="none" stroke="#000" '
        'marker-start="url(#ma)" marker-mid="url(#ma)" marker-end="url(#ma)"/>\n</svg>\n',
    )

    # ---- T84: <image> of an SVG document -------------------------------
    # An SVG image that embeds itself as far as a data: URI can: eight levels,
    # each one the previous wrapped in another <image>.  Only the outermost
    # renders; the ones inside a sub-document load nothing.
    doll = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
            '<rect width="10" height="10" fill="red"/></svg>')
    for _ in range(8):
        doll = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
                '<rect width="10" height="10" fill="green"/>'
                '<image width="10" height="10" href="data:image/svg+xml;base64,'
                + base64.b64encode(doll.encode()).decode() + '"/></svg>')
    write_text(
        "svg_image_self_nest.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"'
        ' width="100" height="100">\n<defs><image id="i" width="100" height="100" '
        'href="data:image/svg+xml;base64,' + base64.b64encode(doll.encode()).decode()
        + '"/></defs>\n' + '<use xlink:href="#i"/>' * 50 + "\n</svg>\n",
    )

    # A huge embedded document (400k elements, ~16 MB of source) used 20
    # times: the element and source-byte budgets (shared with the parent)
    # admit two copies and skip the rest.
    huge = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
            + '<rect x="1" y="1" width="1" height="1"/>' * 400_000 + "</svg>")
    write_text(
        "svg_image_huge_doc.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"'
        ' width="100" height="100">\n<defs><image id="h" width="100" height="100" '
        'href="data:image/svg+xml,' + huge.replace("<", "%3C").replace(">", "%3E").replace('"', "%22")
        + '"/></defs>\n' + '<use xlink:href="#h"/>' * 20 + "\n</svg>\n",
    )

    # An svgz zip bomb: 512 MiB of whitespace inside an <svg>, gzipped to
    # about 500 KB and used 100 times.  Inflating stops past the 64 MiB
    # budget and the failure spends it, so it is inflated once.
    comp = zlib.compressobj(9, zlib.DEFLATED, 31)
    body = comp.compress(b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">')
    pad = b" " * (1 << 20)
    for _ in range(512):
        body += comp.compress(pad)
    body += comp.compress(b"</svg>") + comp.flush()
    write_text(
        "svg_image_svgz_bomb.svg",
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"'
        ' width="100" height="100">\n<defs><image id="z" width="100" height="100" '
        'href="data:image/svg+xml;base64,' + base64.b64encode(body).decode()
        + '"/></defs>\n' + '<use xlink:href="#z"/>' * 100
        + '\n<rect x="10" y="10" width="20" height="20"/>\n</svg>\n',
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
    tmpdir = Path(tempfile.mkdtemp(prefix="lean-svg_adv_"))
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
            if proc.stdout or proc.stderr:
                result["violations"].append(
                    "wrote to stdout/stderr: %r" % (proc.stdout + proc.stderr)[:200]
                )
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            rc = None
            stderr = (exc.stderr or b"").decode("utf-8", "replace")
        result["ms"] = (time.perf_counter() - start) * 1000.0
        result["rc"] = rc
        result["stderr"] = stderr.strip()

        if timed_out:
            result["violations"].append("timed out after %ds" % RENDER_TIMEOUT)
        elif rc not in (0, 1, 2):
            result["violations"].append(
                "return code %d (expected 0, 1 or 2%s)"
                % (rc, "; negative means a signal" if rc < 0 else "")
            )

        for marker in CRASH_MARKERS:
            if marker in stderr:
                result["violations"].append("stderr contains %r" % marker)

        exists = out_png.is_file()
        result["output"] = exists
        if not timed_out:
            if rc in (0, 2) and not exists:
                result["violations"].append("exited %d but wrote no out.png" % rc)
            if rc == 1 and exists:
                result["violations"].append("exited %d but still wrote out.png" % rc)

        strays = sorted(p.name for p in tmpdir.iterdir() if p.name not in ALLOWED_OUTPUTS)
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


def check_no_clobber(binary):
    """No-clobber: a second render to an existing output must be refused,
    leaving that file exactly as it was."""
    result = {
        "name": "no_clobber",
        "rc": None,
        "ms": None,
        "output": False,
        "stderr": "",
        "violations": [],
    }
    tmpdir = Path(tempfile.mkdtemp(prefix="lean-svg_adv_"))
    svg = sorted(SVG_DIR.glob("*.svg"))[0]
    out_png = tmpdir / "out.png"
    try:
        first = subprocess.run(
            [str(binary), str(svg), str(out_png)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=RENDER_TIMEOUT,
        )
        if first.returncode not in (0, 2) or not out_png.is_file():
            result["violations"].append(
                "setup render failed: rc=%s %s"
                % (first.returncode, first.stderr.decode("utf-8", "replace").strip())
            )
            return result
        before = out_png.read_bytes()

        start = time.perf_counter()
        second = subprocess.run(
            [str(binary), str(svg), str(out_png)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=RENDER_TIMEOUT,
        )
        result["ms"] = (time.perf_counter() - start) * 1000.0
        result["rc"] = second.returncode
        result["stderr"] = second.stderr.decode("utf-8", "replace").strip()
        result["output"] = out_png.is_file()

        if second.returncode != 1:
            result["violations"].append("second render into an existing file succeeded")
        after = out_png.read_bytes()
        if after != before:
            result["violations"].append("existing output was modified despite the refusal")
        strays = sorted(p.name for p in tmpdir.iterdir() if p.name not in ALLOWED_OUTPUTS)
        if strays:
            result["violations"].append(
                "stray files in the output directory: %s" % ", ".join(strays)
            )
    except subprocess.TimeoutExpired:
        result["violations"].append("timed out after %ds" % RENDER_TIMEOUT)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return result


def check_image_refs_inert(binary):
    """T63: an `<image>` whose href is not a `data:` URI (a path, `file:`,
    `http:`) must render byte-identically to the same file with every
    `<image>` removed: nothing is loaded, nothing is drawn."""
    result = {
        "name": "image_refs_inert",
        "rc": None,
        "ms": None,
        "output": False,
        "stderr": "",
        "violations": [],
    }
    tmpdir = Path(tempfile.mkdtemp(prefix="lean-svg_adv_"))
    src = ADV_DIR / "image_refs.svg"
    try:
        stripped = tmpdir / "stripped.svg"
        stripped.write_text(re.sub(r"<image\b[^>]*/>", "", src.read_text()))
        outs = []
        start = time.perf_counter()
        for svg, name in ((src, "a.png"), (stripped, "b.png")):
            proc = subprocess.run(
                [str(binary), str(svg), str(tmpdir / name)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=RENDER_TIMEOUT,
            )
            result["rc"] = proc.returncode
            result["stderr"] = proc.stderr.decode("utf-8", "replace").strip()
            if proc.returncode not in (0, 2):
                result["violations"].append("render of %s failed" % svg.name)
                return result
            outs.append((tmpdir / name).read_bytes())
        result["ms"] = (time.perf_counter() - start) * 1000.0
        result["output"] = True
        if outs[0] != outs[1]:
            result["violations"].append("non-data: image hrefs changed the output")
    except subprocess.TimeoutExpired:
        result["violations"].append("timed out after %ds" % RENDER_TIMEOUT)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return result


def check_foreignobject_refs_inert(binary):
    """Rowan: HTML inside `<foreignObject>` (T104) must never load anything.
    Every resource-bearing element and CSS `url()`/`@import` in
    `foreignobject_refs.svg` is stripped from a copy; both files must render
    byte-identically, so nothing external is read or drawn (the text stays)."""
    result = {"name": "foreignobject_refs_inert", "rc": None, "ms": None,
              "output": False, "stderr": "", "violations": []}
    tmpdir = Path(tempfile.mkdtemp(prefix="lean-svg_adv_"))
    src = ADV_DIR / "foreignobject_refs.svg"
    try:
        text = src.read_text()
        text = re.sub(r"<(img|link|embed)\b[^>]*/>", "", text)
        text = re.sub(r"<(iframe|object|video|script)\b.*?</\1>", "", text, flags=re.S)
        text = re.sub(r"@import[^;]*;", "", text)
        text = re.sub(r"background(-image)?:\s*url\([^)]*\);?", "", text)
        stripped = tmpdir / "stripped.svg"
        stripped.write_text(text)
        outs = []
        start = time.perf_counter()
        for svg, name in ((src, "a.png"), (stripped, "b.png")):
            proc = subprocess.run([str(binary), str(svg), str(tmpdir / name)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=RENDER_TIMEOUT)
            result["rc"] = proc.returncode
            if proc.stdout or proc.stderr:
                result["violations"].append("wrote to stdout/stderr")
            if proc.returncode not in (0, 2):
                result["violations"].append("render of %s failed" % svg.name)
                return result
            outs.append((tmpdir / name).read_bytes())
            leftovers = sorted(p.name for p in tmpdir.iterdir()
                               if p.name not in ("a.png", "b.png", "stripped.svg"))
            if leftovers:
                result["violations"].append("unexpected files written: %s" % leftovers)
        result["ms"] = (time.perf_counter() - start) * 1000.0
        result["output"] = True
        if outs[0] != outs[1]:
            result["violations"].append("foreignObject resources changed the output")
    except subprocess.TimeoutExpired:
        result["violations"].append("timed out after %ds" % RENDER_TIMEOUT)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return result


def check_max_input_size(binary):
    """A file over the input size limit (64 MiB) must be rejected cleanly,
    like every other hostile input: rc 1, no output, no hang."""
    result = {
        "name": "oversized_input",
        "rc": None,
        "ms": None,
        "output": False,
        "stderr": "",
        "violations": [],
    }
    tmpdir = Path(tempfile.mkdtemp(prefix="lean-svg_adv_"))
    max_input = 64 * 1024 * 1024
    svg = tmpdir / "oversized.svg"
    try:
        with open(svg, "wb") as f:
            f.write(b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><!--')
            f.write(b"A" * (max_input + 1))
        run_case_result = run_case(svg, binary, "oversized_input")
        result.update(run_case_result)
        if result["rc"] == 0:
            result["violations"].append("an over-limit input was accepted")
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
        "--bin", default=str(DEFAULT_BIN), help="path to the lean-svg binary"
    )
    args = parser.parse_args()

    binary = Path(args.bin).resolve()
    if not binary.is_file():
        print("lean-svg binary not found at %s" % binary, file=sys.stderr)
        print("build it first:  lake build", file=sys.stderr)
        return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("generating adversarial cases in %s ..." % GEN_DIR)
    generated = generate_cases()

    cases = [(p, "corpus/" + p.name) for p in sorted(ADV_DIR.iterdir()) if p.is_file()]
    cases += [(p, "gen/" + p.name) for p in generated]
    if args.filter:
        cases = [c for c in cases if args.filter in c[1]]

    extra_checks = {"no_clobber": check_no_clobber, "oversized_input": check_max_input_size,
                    "image_refs_inert": check_image_refs_inert,
                    "foreignobject_refs_inert": check_foreignobject_refs_inert}
    extra_names = [n for n in extra_checks if not args.filter or args.filter in n]
    if not cases and not extra_names:
        print("no adversarial cases to run", file=sys.stderr)
        return 2

    print("running %d cases (timeout %ds each)\n" % (len(cases) + len(extra_names), RENDER_TIMEOUT))
    results = [run_case(path, binary, label) for path, label in cases]
    results += [extra_checks[name](binary) for name in extra_names]

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
