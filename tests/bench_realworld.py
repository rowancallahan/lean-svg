"""Usage: OUT=dir N=2 python3 tests/bench_realworld.py   (DECISIONS.md, phase 5)

Time lean-svg, resvg and Chromium on the real-world corpus at 1000 px.
lean-svg / resvg: wall time of one CLI run each (process start, parse, render,
PNG write), best of N. Chromium: one warm headless browser; per file, time
Image decode + drawImage onto a 1000-px canvas + a pixel read-back (forces the
raster), best of N. Writes bench.csv."""
import csv, os, subprocess, sys, time, json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(os.environ.get("OUT", "/tmp/bench_realworld"))
OUT.mkdir(parents=True, exist_ok=True)
N = int(os.environ.get("N", "2"))
files = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "tests/corpora/realworld").rglob("*.svg") if "/src/" not in str(p))

def cli(cmd):
    best = 1e9
    for _ in range(N):
        t = time.perf_counter(); r = subprocess.run(cmd, capture_output=True); dt = time.perf_counter() - t
        best = min(best, dt)
    return best * 1000, r.returncode

rows = []
tmp = OUT / "tmp"; tmp.mkdir(exist_ok=True)
for i, f in enumerate(files):
    src = str(ROOT / f)
    o1 = tmp / "a.png"; o2 = tmp / "b.png"
    def ours():
        if o1.exists(): o1.unlink()
        return [str(ROOT / ".lake/build/bin/lean-svg"), src, str(o1), "--width", "1000"]
    best = 1e9
    for _ in range(N):
        cmd = ours(); t = time.perf_counter(); r = subprocess.run(cmd, capture_output=True); best = min(best, time.perf_counter() - t)
    ms_ours, rc_ours = best * 1000, r.returncode
    ms_resvg, rc_resvg = cli(["resvg", "-w", "1000", src, str(o2)])
    rows.append({"file": f, "bytes": os.path.getsize(src), "ms_ours": round(ms_ours, 1), "rc_ours": rc_ours,
                 "ms_resvg": round(ms_resvg, 1), "rc_resvg": rc_resvg})
    if i % 100 == 0: print(i, file=sys.stderr, flush=True)

from playwright.sync_api import sync_playwright
JS = """async ([url, n]) => {
  let best = 1e9;
  for (let k = 0; k < n; k++) {
    const t = performance.now();
    const img = new Image(); img.src = url + '?' + k + Math.random(); await img.decode();
    const w = 1000, h = Math.max(1, Math.round(1000 * img.naturalHeight / Math.max(1, img.naturalWidth)));
    const c = new OffscreenCanvas(w, h); const ctx = c.getContext('2d');
    ctx.drawImage(img, 0, 0, w, h); ctx.getImageData(0, 0, 1, 1);
    best = Math.min(best, performance.now() - t);
  }
  return best;
}"""
with sync_playwright() as p:
    b = p.chromium.launch(args=["--allow-file-access-from-files"])
    pg = b.new_page(); pg.goto("file://" + str(ROOT))
    for r in rows:
        try: r["ms_chrome"] = round(pg.evaluate(JS, ["file://" + str(ROOT / r["file"]), N]), 1)
        except Exception as e: r["ms_chrome"] = ""
    b.close()
with open(OUT / "bench.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
print("done", len(rows))
