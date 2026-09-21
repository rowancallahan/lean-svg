# T4m — Merge the viewport branch onto the new rasterizer

## Situation

Branch `t4-viewport` (see `tasks/T4-viewport-tiles.md` Report) adds
`--viewport X Y W H` tile rendering and `tests/run_tiles.py`, and it fixed
tile-border identity by changing the *old* accumulation rasterizer. Since
then `main` replaced `LeanSvg/Raster.lean` entirely (T1: tiny-skia
supersampling port) and changed opacity plumbing (T5). A plain merge
conflicts in `Raster.lean`, `Render.lean`, `DESIGN.md`.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T4m` (branch
`t4m-merge`, created from `main`). Do not commit the merge yourself; leave
the worktree in a clean, built, tested state with the merge staged or
committed on the branch (a commit on the branch is fine; do not touch `main`).

## Steps

1. `git merge t4-viewport`. Resolve:
   - `LeanSvg/Raster.lean`: take **main's version unchanged** (`git checkout
     --ours`). T4's `Rect`/`accumEdge`/`accumPiece` changes belong to the old
     rasterizer and must not be resurrected.
   - `LeanSvg/Render.lean`: keep T4's `Options.viewport`, the tile size and
     `translate(−X·256, −Y·256)` composition in `canvasSetup`, but call
     main's `Raster.rasterize W H dev evenOdd` (no document-rectangle
     argument), and keep main's `opacityToU8` calls from T5 in `drawShape`.
   - `Main.lean`: T4's version (viewport parsing, usage text).
   - `DESIGN.md`: keep main's §3.5 (T1's description); add T4's §3.8
     viewport section. `README.md`, `Makefile`: T4's additions.
2. `lake build` clean. `python3 tests/run_tests.py` must reproduce main's
   current table exactly (15/20, same metrics; compare against a render of
   the corpus from main's binary at `/Users/rowancallahan/pdf_renderer/.lake/build/bin/lean-svg`
   by sha256 of the PNGs, all must be identical).
3. `python3 tests/run_tiles.py`. Expected: byte-identical stitching, because
   the new rasterizer's edge setup rounds relative to whole-pixel mask
   origins (`top = (y0+32)>>6`, `x = (x0 + ...) << 10` shift by exact
   multiples when the origin moves by whole pixels) and clamps out-of-mask
   sub-columns rather than re-interpolating. If it is **not** identical,
   find the mask-origin dependence in `mkEdge`/`blitSpan`/`rasterize` and
   fix it minimally in `Raster.lean`, keeping the no-viewport corpus
   byte-identical (re-check the sha256s) and explaining the cause.
4. `python3 tests/run_adversarial.py` clean. Re-time the three 512×512 tiles
   at `--width 4000` from T4's report and note the numbers.
5. Append `## Report` here: conflicts and how resolved, tile identity
   result, timings, sha256 check result.

---

## Report

### Conflicts and how each was resolved

`git merge t4-viewport` conflicted in three files; `Main.lean`, `Makefile`,
`README.md`, `tasks/T4-viewport-tiles.md` and `tests/run_tiles.py` merged
cleanly (T4's versions — `main` never touched them).

| file | resolution |
|---|---|
| `LeanSvg/Raster.lean` | `git checkout --ours`: **main's file, unchanged**. `git diff main -- LeanSvg/Raster.lean` is empty. T4's `Rect` / `accumEdge` / `accumPiece` work belonged to the old accumulation rasterizer and is gone with it. |
| `LeanSvg/Render.lean` | Hand-merged. Kept T4's `Options.viewport`, the tile canvas size and the `Mat.translate (−X·256) (−Y·256)` composition in `canvasSetup`; dropped the `Raster.Rect` argument so the calls are main's `Raster.rasterize W H dev evenOdd`; kept main's T5 `opacityToU8 c.a st.fillOpacity st.opacity` / `… st.strokeOpacity …` in `drawShape`. `canvasSetup`'s fourth result is now a `Clip` (see below), not a document rectangle for the rasterizer. |
| `DESIGN.md` | §3.5 is main's (T1's supersampling description) with a new closing paragraph on why the scheme is invariant under whole-pixel shifts; T4's §3.5 replacement (about `accumPiece` and document-rectangle clipping) was dropped entirely. §3.8 "Viewport (tiles)" kept from T4 and rewritten: the identity argument is now the whole-pixel-shift one, plus the `clipMask` paragraph. |

`LeanSvg/Effect.lean` untouched; `tests/run_tests.py` and
`tests/run_adversarial.py` untouched.

### sha256 corpus check — 80/80 identical

Every corpus file rendered four ways (default, `--width 800`,
`--width 1600 --background white`, `--zoom 2.5`) with main's binary at
`/Users/rowancallahan/pdf_renderer/.lake/build/bin/lean-svg` and with the merged
binary: **80 renders compared, 0 mismatching**. Re-run after the `clipMask`
change below: still 80/80. The no-viewport path is therefore byte-identical to
main by measurement, and `python3 tests/run_tests.py` reproduces main's table —
**15/20**, every quality column equal to the numbers in T5's/T1's current main
table (01 100.000, 12_badge 92.838/97.659, 16_stress 78.413/95.831,
18_rose 99.216/99.680, …); only the `ms` columns move.

### Tile identity on the new rasterizer

**Stitching is byte-identical on all 20 corpus files, with no change to
`Raster.lean`.** The prediction in step 3 holds: the tile transform differs from
the full-image transform by `Mat.translate` alone, whose linear part is the
identity, so `Mat.mul` only adds `(−256X, −256Y)` to the translation — exactly,
no `ediv` rounding — and device geometry inside a tile is the whole image's
geometry shifted by a whole number of pixels. Under such a shift:

* the mask origin `(max(0, ⌊min⌋), …)` moves by whole pixels, so `p.x − ox` is
  either unchanged or shifted by a multiple of 256 `Fx`;
* `top`/`bottom = (y ± 32) >> 6` move by a multiple of 4 sub-scanlines, leaving
  `dy` and `slope` bit-identical, and `x = (x₀ + …) << 10` moves by a multiple
  of `4 · 65536`, i.e. whole sub-columns, so `(x + 0x8000) >> 16` shifts by
  exactly 4 per pixel of offset;
* therefore `y &&& 3` keeps its phase (same `64,64,64,63` assignment per
  document row), and `blitSpan`'s `s >>> 2` / `s &&& 3` see the same pixel and
  the same quarter-pixel remainder;
* clipping is by *clamping* (`xr ≤ 0 → 0`, `xr ≥ nSuper → nSuper`) and by
  dropping whole sub-scanlines, never by re-interpolating, and the `loPin` /
  `hiPin` pinning in `mkEdge` is exactly that same clamp applied early, so a
  span truncated at a mask edge still leaves the last in-mask pixel "interior".

So no fix was needed in `Raster.lean` for stitching, and none was made.

### The one thing that did break, and the fix (`Render.lean`, not `Raster.lean`)

`run_tiles.py` failed one check on one file: *"16_stress_2000: partial tile is
not transparent outside the document"* (tile `--viewport -20 -20 100 100`,
3122 painted pixels in the 20 px strip left of and above the document).

Cause: T4's document rectangle was doing two jobs, and only one of them is
about rounding. The other is the **SVG viewport clip**. In a full render the
canvas *is* the document, so `rasterize`'s clip to `W × H` discards everything
outside it; in a tile the canvas is the tile, so shapes that stick out past the
document's edge (16_stress_2000 has plenty) get drawn in the part of the tile
that lies outside the document — where a full render shows nothing. Off-document
tiles further out still came back clear, which is why only the partial-tile
check caught it.

Fixed in `LeanSvg/Render.lean`: `canvasSetup` also returns `Clip`, the
document's window in canvas pixels (`(0, 0, W, H)` normally, and
`(max(0,−X), max(0,−Y), min(w, W−X), min(h, H−Y))` for a tile), and `drawShape`
pipes every mask through `clipMask`, which crops it to that window. When the
mask already lies inside the window — always, without `--viewport` — `clipMask`
returns it unchanged, which is why the 80 sha256s stayed identical. Invariants
hold: no `partial`/`unsafe`/`@[extern]`/`panic!`/`!`-indexing, no `Float`, both
new loops are `for` over ranges bounded by the mask, `lake build` clean with no
warnings (verified with every module forced to rebuild).

After the fix: `run_tiles.py` is **20/20 — stitch exact, off-document clear,
partial exact**. An extra ad-hoc sweep (all 20 files × 5 tiles hanging off the
right, bottom, left+bottom and right+top edges, odd sizes, plus tiles entirely
past an edge) is pixel-equal to the transparent-padded crop of the full render
in every case.

### Interactive tile timings

512×512 tile at `--width 4000`, `--viewport 1744 1744 512 512`, median of 5,
wall clock including process start, same machine as T4's report:

| file | T4 (old rasterizer) | now | ratio |
|---|---|---|---|
| `12_badge` | 457.6 ms | **963.4 ms** | ×2.11 |
| `16_stress_2000` | 587.2 ms | **879.4 ms** | ×1.50 |
| `18_rose_lissajous` | 220.3 ms | **613.2 ms** | ×2.78 |

(`run_tiles.py`'s own run of the same measurement reported 1080 / 948 / 669 ms;
three sibling worktrees were building and testing throughout, load average
3.4–5.8, so treat these as upper bounds.) The slowdown is the supersampling
rasterizer's, not the merge's: T1 measured the same ≈2× on whole-corpus renders.
`clipMask` costs four comparisons per mask on this path.

### Checks

* `lake build` — clean, no warnings (full rebuild).
* `python3 tests/run_tests.py` — 15/20, metrics identical to main.
* sha256, 20 files × 4 CLI modes, main's binary vs this one — 80/80 identical.
* `python3 tests/run_tiles.py` — 20/20 exact stitch, off-document clear,
  partial exact; timings above.
* `python3 tests/run_adversarial.py` — **37/37 cases clean, 0 with violations**
  (the task file says 28/28; the suite generates more cases now, and T1's and
  T4's reports both already record 37/37).
* Committed on `t4m-merge`; `main` untouched.
