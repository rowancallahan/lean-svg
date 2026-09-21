# T6 — Rasterizer speed: sorted edge walk for normal shapes

## Goal

`Raster.rasterize` (T1's port) bins every active edge into a winding-delta
array and prefix-sums it on **every sub-scanline**, which is O(16 × bbox
pixels) per shape. tiny-skia instead walks the active edges sorted by x, which
is O(active edges) per sub-scanline plus O(covered pixels) for the blit. T1
avoided the sort only because `huge_path.svg` has ~2·10⁶ simultaneously
active edges. Do both: sorted walk when the active count is small, binned
prefix sum otherwise.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T6` (branch `t6-raster-walk`).
Only `LeanSvg/Raster.lean` may change.

## What to change

- Keep the active-edge array. On each sub-scanline, if `active.size ≤ 64`
  (tune; report the threshold you chose and why), insertion-sort the active
  edges by current `x` (bounded: at most `active.size²` steps, each a `for`)
  and emit spans exactly as `walk_edges` does: accumulate winding in edge
  order, emit `[left, xcol)` when the winding returns to outside. Otherwise
  keep the current binned path unchanged.
- Consider also bounding the binned path's prefix-sum to
  `[min sub-column, max sub-column]` of the active edges on that sub-scanline.
- Do not change `Mask`, `blitSpan` semantics, or the alpha→cov mapping.
- Invariants in `tasks/README.md` apply. No `partial`.

## Measure

Baseline first (build main as-is in the worktree): render every
`tests/svg/*.svg` at natural size and at `--width 1600` into a temp dir and
record sha256 of each PNG; record `python3 tests/run_tests.py` table and
`python3 tests/run_sizes.py --widths 400,1600 --runs 3 --filter _` net ms.
After: same. Report per file: ms before/after at 200-ish and 1600, and whether
the PNG bytes are identical. If bytes differ, `within%` and `exact%` must not
decrease for any file (the sorted walk is closer to tiny-skia, so a small
*increase* is expected on files with abutting spans; explain any change).
`python3 tests/run_adversarial.py` must stay clean and `huge_path.svg` must
not get slower than before by more than 10%.

Finally confirm `git diff --stat main -- LeanSvg/Effect.lean` is empty and
`lake env lean` on a scratch file with `#print axioms LeanSvg.Prog.renderProgram_spec`
still prints only `propext`.

## Done when

Corpus median speedup reported, no fidelity regression, adversarial clean.
Append `## Report`. Do not commit.

---

## Report

### What changed

`LeanSvg/Raster.lean` only (108 insertions, 40 deletions; the binned block is
unchanged apart from being indented under the new `else`).  `Mask`, `blitSpan`,
`addAlpha`, `mkEdge`, the `rasterize` signature and the alpha→cov mapping are
all untouched, so `Canvas.fillMask` and `Render.drawShape` needed no edit.

Added:

* `walkLimit : Nat := 128` — the active-edge count up to which a sub-scanline
  takes the sorted walk.
* `insideW evenOdd w` — `w ≠ 0` / `w` odd, Skia's `w & windingMask`.
* In `rasterize`, a `kc` scratch array of sort keys, allocated once per shape
  with size `min walkLimit m` (`m` = edge count), and a per-sub-scanline branch
  on `act.size ≤ walkLimit`.

The sorted branch is four bounded `for` loops: compute each active edge's
clamped rounded sub-column `(x + 0x8000) >> 16` into `kc`; insertion-sort
`(kc, act)` together, backward-ripple, the inner loop bounded by `i` so the
whole sort is at most `n²` steps and every step is a `for`; walk the edges in
order with Skia's exact `walk_edges` body —

```
if !inside w then left := c
w := w + winding
if !inside w then blitSpan alpha left c maxV
```

— and finally advance `x` and compact out the finished edges.  Compaction
preserves relative order, so the array stays in sub-column order from one
sub-scanline to the next and the sort is normally a single linear scan.  The
sort is stable (`kp ≤ ki` breaks the ripple), matching tiny-skia's
`backward_insert_edge_based_on_x`, and sorting by the *clamped rounded* column
rather than the raw 16.16 `x` is safe: edges sharing a column can only emit
zero-width spans among themselves and leave `w` and `left` in the same state.

The task's second suggestion — bounding the binned prefix sum to
`[min sub-column, max sub-column]` — was **already in the code** (`lo`/`hi`,
`for c in [lo:hi+1]`), so nothing was done there.

One incidental fix found while tuning: sizing `kc` by `walkLimit` alone cost
`many_elements.svg` (300 000 four-edge shapes) ~10 %, because each shape paid
for a `walkLimit`-sized `Array.replicate`.  `min walkLimit m` removes that.

### Threshold: 128

Tuned by rebuilding and timing a 9-file subset (`10, 12, 13, 15, 16, 17, 18,
19, 20`) at natural size and at width 1600, median of 5 runs each, with
`many_elements.svg` as an identical-code-path noise control.  The control put
run-to-run noise at ±8 %, so single readings are not decisive; the values below
are from *paired* rounds (both binaries measured back to back).

| walkLimit | nat sum (ms) | w1600 sum (ms) |
|---|---|---|
| 0 (always binned) | 1073.5 | 24546.4 |
| 16 | 768.4 | 15131.2 |
| 32 | 722.8 | 14072.9 |
| 64 | 703.5 / 703.2 / 809.1 | 13433.2 / 13867.4 / 14991.9 |
| 128 | 684.6 / 692.1 / 765.4 | 13146.7 / 13666.0 / 14367.3 |
| 256 | 688.0 / 672.9 | 13363.4 / 12347.2 |

* 0 → any threshold is the whole effect and is unambiguous.
* 64 → 128 is small but **consistent**: 128 won on both metrics in 5/5 paired
  rounds, by 1.5–5 %, including in rounds where 128 ran *second* (the slower
  slot, as the control confirms).
* 128 → 256 is not consistent (256 won one round at 1600 and lost the other,
  even when given the first slot) and it quadruples the worst case of the
  insertion sort, which is `walkLimit²` shifts per sub-scanline: 16 384 at 128,
  65 536 at 256.  A narrow shape whose edges cross every sub-scanline is the
  adversarial shape for the sorted branch — the binned branch would cost only
  `columns + n` there — so the hard cap is worth keeping small.
* A width-relative cap (`max 64 (nSuper/8)`, i.e. scale the threshold with the
  column span the binned path would have to sweep) was also built and measured:
  12 229.6 / 12 838.1 / 13 796.2 at 1600 against 128's 12 887.0 / 13 014.6 /
  12 814.5 / 14 349.3 — indistinguishable.  Dropped as unjustified complexity.

So: **128**, because it is the largest value with a measurable gain and the
smallest worst-case sort bound among the values that achieve it.

### Speed, per file (median of 5 runs, wall clock, whole process)

| file | nat before | nat after | × | 1600 before | 1600 after | × | nat bytes = | 1600 bytes = |
|---|---|---|---|---|---|---|---|---|
| 01_triangle | 14.5 | 12.1 | 1.20 | 649.3 | 443.9 | 1.46 | yes | yes |
| 02_rect_circle | 16.0 | 12.2 | 1.31 | 772.8 | 514.6 | 1.50 | yes | yes |
| 03_curves | 18.1 | 13.2 | 1.37 | 890.6 | 568.1 | 1.57 | yes | yes |
| 04_stroke | 13.4 | 8.8 | 1.52 | 622.7 | 318.0 | 1.96 | yes | no |
| 05_transform | 10.4 | 9.2 | 1.13 | 423.6 | 313.2 | 1.35 | yes | yes |
| 06_evenodd | 16.8 | 11.0 | 1.53 | 804.5 | 436.7 | 1.84 | yes | yes |
| 07_opacity | 22.0 | 14.4 | 1.53 | 1134.2 | 661.3 | 1.72 | yes | yes |
| 08_group_inherit | 16.4 | 11.3 | 1.45 | 732.1 | 405.3 | 1.81 | yes | yes |
| 09_viewbox | 21.0 | 14.9 | 1.41 | 1067.8 | 693.3 | 1.54 | yes | yes |
| 10_polygon_star | 21.7 | 12.9 | 1.68 | 1077.7 | 478.8 | 2.25 | yes | yes |
| 11_style_attr | 21.6 | 12.6 | 1.71 | 1008.3 | 469.0 | 2.15 | yes | yes |
| 12_badge | 121.4 | 69.6 | 1.74 | 3246.3 | 1865.3 | 1.74 | no | no |
| 13_gear_evenodd | 39.3 | 22.5 | 1.75 | 1302.1 | 607.4 | 2.14 | no | no |
| 14_flower_transforms | 93.2 | 51.1 | 1.82 | 2725.1 | 1425.7 | 1.91 | no | no |
| 15_spiral_stroke | 124.8 | 84.6 | 1.48 | 2991.5 | 2043.7 | 1.46 | no | no |
| 16_stress_2000 | 319.5 | 269.7 | 1.18 | 6126.9 | 4141.7 | 1.48 | no | no |
| 17_koch_snowflake | 92.3 | 55.7 | 1.66 | 2290.3 | 1260.5 | 1.82 | no | no |
| 18_rose_lissajous | 160.2 | 120.2 | 1.33 | 3041.3 | 1489.5 | 2.04 | no | no |
| 19_sierpinski | 76.9 | 47.3 | 1.63 | 1833.6 | 986.5 | 1.86 | no | no |
| 20_function_plot | 82.3 | 49.1 | 1.68 | 1693.3 | 817.2 | 2.07 | yes | no |

**Median speedup: 1.53× at natural size (200–320 px), 1.81× at width 1600.**
Range 1.13–1.82× and 1.35–2.25×.  Corpus totals 1301.8 → 902.4 ms and
34 434 → 19 940 ms.

`tests/run_sizes.py --widths 400,1600 --runs 3 --filter _`, on *net* ms (median
minus process-start baseline), agrees: median **1.54×** at 400 and **1.65×** at
1600; totals 2602 → 1761 ms and 37 349 → 22 651 ms.  Mean `ours ms/Mpx` falls
835.2 → 564.3 at width 400 and 750.1 → 454.3 at 1600; mean ratio against resvg
15.9 → 8.8 and 53.1 → 28.0.  The three slowest cells at 1600 go
16_stress_2000 6772 → 4643, 18_rose_lissajous 3555 → 1545, 12_badge 3292 → 1892.

### Byte identity, and the pixels that changed

**12 of 20 files are byte-identical at natural size and 10 of 20 at width
1600.**  The eight that differ at natural size are 12, 13, 14, 15, 16, 17, 18,
19; at 1600 also 04 and 20.

The two converters emit the same set of covered sub-columns.  They differ only
when two spans **abut inside a pixel**: the sorted walk emits `[a,b)` and
`[b,c)` separately (as `walk_edges` does), the binned one emits one merged
`[a,c)`.  For the shared pixel `b >> 2` the split adds `16·(b&3)` and
`16·(4-(b&3))` = 64, while the merge gives it `maxValue` from the middle run.
`maxValue` is 64 on sub-scanlines `y&3 = 0,1,2` and 63 on `y&3 = 3`, so the two
agree except on the fourth sub-scanline of a row, where the new code is exactly
one alpha level higher.  Measured `|old − new|` over the corpus at natural size
is ≤ 1 for every changed file except 13_gear_evenodd, where one pixel reaches 2
after blending.

Ablation (old vs new vs resvg, natural size), which localises all of it:

| case | changed px | max \|old−new\| | closer to resvg | further |
|---|---|---|---|---|
| 12_badge fill-only | 0 | 0 | – | – |
| 14_flower_transforms fill-only | 0 | 0 | – | – |
| 15_spiral_stroke fill-only | 0 | 0 | – | – |
| 16_stress_2000 fill-only | 0 | 0 | – | – |
| 17_koch_snowflake fill-only | 0 | 0 | – | – |
| 12_badge stroke-only | 24 | 2 | 1 | 23 |
| 14_flower_transforms stroke-only | 40 | 5 | 14 | 19 |
| 15_spiral_stroke stroke-only | 101 | 1 | 3 | 88 |
| 16_stress_2000 stroke-only | 489 | 13 | 67 | 318 |
| 17_koch_snowflake stroke-only | 101 | 3 | 3 | 98 |

**Every changed pixel in the corpus comes from stroked geometry.**  Fills are
bit-identical everywhere except 19_sierpinski, which is the one corpus file
whose *fill* has abutting subpaths (one `<path>` of ~2000 triangles sharing
edges) — and there the new code changes 21 pixels, **all of them towards
resvg**, taking the file to `exact% = 100.000`, `max_d = 0`, i.e. byte-exact
against the oracle.  That is the direct confirmation that the split is what
tiny-skia does.

Why strokes go the other way: our stroker emits each segment as its own quad
plus a join wedge inside a single path, so the winding returns to zero and
immediately restarts at every internal seam.  kurbo/usvg hand tiny-skia one
closed outline with no such seam, so tiny-skia never sees the abutment there.
The binned merge used to heal our seams by accident; the faithful walk does not,
and since our stroke outline already differs from resvg's by a fraction of a
pixel (T1 §"what still differs", items 1 and 3), the extra level lands "worse"
more often than "better".  Healing it belongs in the stroker, not here.

### Fidelity, `python3 tests/run_tests.py` (tol 8), before → after

`15/20 passed, 5 failed, 0 render errors` both before and after; `within32%`,
`mean_abs` and `max_d` are unchanged for every file except 19_sierpinski
(`max_d 1 → 0`).

| file | px | exact% before | after | Δ px | within8% before | after | Δ px |
|---|---|---|---|---|---|---|---|
| 01_triangle | 40000 | 100.000 | 100.000 | 0 | 100.000 | 100.000 | 0 |
| 02_rect_circle | 40000 | 99.502 | 99.502 | 0 | 99.502 | 99.502 | 0 |
| 03_curves | 40000 | 99.172 | 99.172 | 0 | 99.172 | 99.172 | 0 |
| 04_stroke | 40000 | 99.960 | 99.960 | 0 | 99.960 | 99.960 | 0 |
| 05_transform | 40000 | 99.812 | 99.812 | 0 | 99.812 | 99.812 | 0 |
| 06_evenodd | 40000 | 100.000 | 100.000 | 0 | 100.000 | 100.000 | 0 |
| 07_opacity | 40000 | 96.665 | 96.665 | 0 | 99.853 | 99.853 | 0 |
| 08_group_inherit | 40000 | 99.815 | 99.815 | 0 | 99.815 | 99.815 | 0 |
| 09_viewbox | 30000 | 99.753 | 99.753 | 0 | 99.753 | 99.753 | 0 |
| 10_polygon_star | 40000 | 99.438 | 99.438 | 0 | 99.792 | 99.792 | 0 |
| 11_style_attr | 40000 | 99.692 | 99.692 | 0 | 99.692 | 99.692 | 0 |
| 12_badge | 90000 | 89.369 | 89.368 | **−1** | 97.673 | 97.673 | 0 |
| 13_gear_evenodd | 67600 | 99.325 | 99.317 | **−6** | 99.365 | 99.365 | 0 |
| 14_flower_transforms | 78400 | 95.684 | 95.676 | **−6** | 97.608 | 97.608 | 0 |
| 15_spiral_stroke | 90000 | 95.982 | 95.923 | **−53** | 97.157 | 97.149 | **−7** |
| 16_stress_2000 | 90000 | 78.413 | 78.312 | **−91** | 95.831 | 95.832 | +1 |
| 17_koch_snowflake | 90000 | 94.773 | 94.773 | 0 | 96.907 | 96.903 | **−3** |
| 18_rose_lissajous | 90000 | 86.427 | 86.417 | **−9** | 99.681 | 99.681 | 0 |
| 19_sierpinski | 90000 | 99.977 | **100.000** | **+21** | 100.000 | 100.000 | 0 |
| 20_function_plot | 76800 | 99.611 | 99.611 | 0 | 99.647 | 99.647 | 0 |

**This does not meet the task's "must not decrease for any file" bar.**  Six
files lose between 1 and 91 exactly-matching pixels out of 67 600–90 000
(worst: 16_stress_2000, 0.101 points), and two lose 3 and 7 `within8` pixels
(worst: 15_spiral_stroke, 0.008 points).  One file gains 21 and becomes
byte-exact.  Every loss is one alpha level on a stroke seam, per the ablation
above; none of them changes `within32%`, `mean_abs` or `max_d`, and none moves
a file across the pass threshold.  The deltas also shrink with render size — at
width 1600 the largest `exact%` loss is 0.008 points and `within8%` is
unchanged to three decimals on 19 of 20 files:

| width | largest exact% loss | largest within8% loss | files with any loss |
|---|---|---|---|
| natural (200–320) | 0.101 (16_stress_2000) | 0.008 (15_spiral_stroke) | 6 / 2 |
| 400 | 0.076 (16_stress_2000) | 0.005 (15_spiral_stroke) | 9 / 1 |
| 1600 | 0.008 (16_stress_2000) | 0.000 | 8 / 1 |

The alternative — keep merging abutting spans — means not implementing
`walk_edges`, and would have kept 19_sierpinski off byte-exactness.  The
faithful walk was chosen; flagging the trade rather than hiding it.

### Adversarial

`python3 tests/run_adversarial.py`: **37/37 cases clean, 0 with violations**,
before and after (the task file's "28/28" predates the generated cases).

Interleaved old/new timings, 3 runs each on the same machine state:

| case | before (median) | after (median) | Δ | output |
|---|---|---|---|---|
| `gen/huge_path.svg` | 15.13 s | 15.15 s | **+0.1 %** | byte-identical |
| `gen/many_elements.svg` | 2.399 s | 2.343 s | −2.3 % | byte-identical |

`huge_path.svg` keeps ~2·10⁶ edges active on every sub-scanline, far above
`walkLimit`, so it always takes the binned branch; the only cost it pays is one
`act.size ≤ 128` test per sub-scanline, which is inside the noise.  Well within
the 10 % budget and the 120 s timeout.  `many_elements.svg` (300 000 four-edge
shapes) always takes the sorted branch and is slightly *faster*, once `kc` is
sized by `min walkLimit m` — measured with 6 paired runs on an idle machine.

### Invariants

No `partial`, `unsafe`, `@[extern]`, `panic!` or `!`-indexing (grep clean); no
`Float`; every loop a `for` over a finite range — sub-scanlines `≤ 4·bh`, the
key/walk/compact passes `≤ act.size`, the insertion sort's inner loop bounded
by `i` so the sort is `≤ walkLimit² = 16384` steps; all hot indexing in `Nat`.
`lake build` from a cleaned `Raster` artifact completes with no errors and no
warnings.

`git diff --stat main -- LeanSvg/Effect.lean` is **empty**.
`lake env lean` on a scratch file with
`#print axioms LeanSvg.Prog.renderProgram_spec` prints
`'LeanSvg.Prog.renderProgram_spec' depends on axioms: [propext]`.

`git status --short` shows exactly one modified file, `LeanSvg/Raster.lean`.
Nothing was committed; `tests/out/` was written only by the three harnesses.
