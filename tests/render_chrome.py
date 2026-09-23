#!/usr/bin/env python3
"""Render SVG files with headless Chromium, as a second reference beside resvg
and the suite's own PNGs (for files resvg is known to get wrong).

    python3 tests/render_chrome.py OUT_DIR WIDTH file.svg [file.svg ...]
    python3 tests/render_chrome.py OUT_DIR WIDTH file.svg [file.svg ...] --jobs 8

Writes OUT_DIR/<basename>.chrome.png at WIDTH px wide, height from the SVG's
aspect ratio, on a transparent background. Files are opened by path, so
relative resources resolve the way a browser would resolve them.

`--jobs N` renders through N pages of a single shared browser instance
concurrently (default 1, sequential) -- one browser launch for the whole
batch either way, so a suite of a thousand-plus files takes minutes, not
hours. `render_batch` is the reusable entry point for callers (e.g.
`run_corpora.py --ref chrome`) that want per-file output stems that do not
collide, instead of the CLI's `<stem>.chrome.png` convention.
"""
import argparse
import asyncio
import sys
from pathlib import Path
from urllib.parse import quote

from playwright.async_api import async_playwright

# the container ships its own Chromium; do not let Playwright download one
CHROME_EXE = "/opt/pw-browsers/chromium"

PAGE = """<!doctype html><html><head><style>
html,body{margin:0;padding:0;background:transparent}
img{display:block;width:%dpx;height:auto}</style></head>
<body><img src="%s"></body></html>"""


async def _render_one(page, src, out_png, width):
    """Render one SVG with `page`. Returns None on success, else an error string."""
    src = src.resolve()
    html = src.parent / (".chrome_%d_%s.html" % (id(page), src.stem))
    # percent-encode: a filename can contain URI-reserved characters (the
    # suite has literal `#`s, e.g. "#RGB-color.svg") that the browser would
    # otherwise parse as part of the URL, not the path -- a `#` truncates
    # `src` at the fragment, silently loading nothing.
    html.write_text(PAGE % (width, quote(src.name, safe="")))
    try:
        await page.goto(html.as_uri())
        await page.wait_for_load_state("networkidle")
        img = page.locator("img")
        box = await img.bounding_box()
        if not box or box["width"] <= 0:
            return "chromium could not render %s" % src
        await img.screenshot(path=str(out_png), omit_background=True)
        return None
    except Exception as exc:  # noqa: BLE001 -- report as a per-file failure, not a crash
        return str(exc).splitlines()[0] if str(exc) else repr(exc)
    finally:
        html.unlink(missing_ok=True)


async def render_batch_async(pairs, out_dir, width, jobs=1):
    """Render (src_path, out_stem) pairs to out_dir/<out_stem>.png.

    One browser launch, `jobs` pages pulling from a shared queue. Returns
    {out_stem: Path or None} -- None means that file failed; the reason is
    printed to stderr as it happens.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    queue = list(pairs)
    results = {}
    async with async_playwright() as p:
        exe = CHROME_EXE if Path(CHROME_EXE).is_file() else None
        browser = await (
            p.chromium.launch(executable_path=exe) if exe else p.chromium.launch()
        )
        pages = [await browser.new_page(device_scale_factor=1) for _ in range(max(1, jobs))]

        async def worker(page):
            while queue:
                try:
                    src, stem = queue.pop()
                except IndexError:
                    return
                out_png = out_dir / (stem + ".png")
                err = await _render_one(page, Path(src), out_png, width)
                if err is not None:
                    print("render_chrome: %s: %s" % (src, err), file=sys.stderr)
                    results[stem] = None
                else:
                    results[stem] = out_png

        await asyncio.gather(*(worker(page) for page in pages))
        await browser.close()
    return results


def render_batch(pairs, out_dir, width, jobs=1):
    """Sync wrapper around `render_batch_async`."""
    return asyncio.run(render_batch_async(pairs, Path(out_dir), width, jobs))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", metavar="OUT_DIR")
    ap.add_argument("width", type=int)
    ap.add_argument("files", nargs="+", metavar="file.svg")
    ap.add_argument("--jobs", type=int, default=1, help="concurrent pages in one browser (default 1)")
    args = ap.parse_args()

    out_dir = Path(args.out)
    # internal stems are index-unique so concurrent pages never write the same
    # file, even when two inputs share a basename (e.g. two "simple-case.svg"
    # in different feature directories); the final rename below then applies
    # the CLI's own <stem>.chrome.png convention, last one wins on a clash,
    # same as the old sequential script.
    pairs = [(Path(f).resolve(), "%06d_%s" % (i, Path(f).stem)) for i, f in enumerate(args.files)]
    results = render_batch(pairs, out_dir, args.width, args.jobs)
    failed = 0
    for src, stem in pairs:
        orig_stem = stem.split("_", 1)[1]
        dest = out_dir / (orig_stem + ".chrome.png")
        got = results.get(stem)
        if got is None:
            failed += 1
            continue
        got.replace(dest)
    if failed:
        print("render_chrome: %d/%d file(s) failed" % (failed, len(pairs)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
