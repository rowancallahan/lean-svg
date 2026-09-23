#!/usr/bin/env python3
"""Render SVG files with headless Chromium, as a second reference beside resvg
and the suite's own PNGs (for files resvg is known to get wrong).

    python3 tests/render_chrome.py OUT_DIR WIDTH file.svg [file.svg ...]

Writes OUT_DIR/<basename>.chrome.png at WIDTH px wide, height from the SVG's
aspect ratio, on a transparent background. The file is opened by path, so
relative resources resolve the way a browser would resolve them.
"""
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

out, width, files = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
assert files, "no input files"
out.mkdir(parents=True, exist_ok=True)
PAGE = """<!doctype html><html><head><style>
html,body{margin:0;padding:0;background:transparent}
img{display:block;width:%dpx;height:auto}</style></head>
<body><img src="%s"></body></html>"""
with sync_playwright() as p:
    # the container ships its own Chromium; do not let Playwright download one
    exe = "/opt/pw-browsers/chromium"
    browser = p.chromium.launch(executable_path=exe) if Path(exe).is_file() else p.chromium.launch()
    page = browser.new_page(device_scale_factor=1)
    for f in files:
        src = Path(f).resolve()
        html = src.parent / (".chrome_" + src.stem + ".html")
        html.write_text(PAGE % (width, src.name))
        page.goto(html.as_uri())
        page.wait_for_load_state("networkidle")
        img = page.locator("img")
        box = img.bounding_box()
        assert box and box["width"] > 0, "chromium could not render %s" % f
        img.screenshot(path=str(out / (src.stem + ".chrome.png")), omit_background=True)
        html.unlink()
    browser.close()
