# T31 — Straight-edge rounding: one supersample off at fractional positions  [Sonnet, Opus fallback]

Finding (SESSION_SUMMARY, "font demo"): a plain axis-aligned rectangle at a
fractional device position differs from resvg on its straight edges by whole
quarter-steps of coverage (63/96/127/128/176 levels), i.e. our edge lands one
supersample row or column away from tiny-skia's. Same result with a positive
or flipped scale, `<rect>` or `<path>`. Curves differ by 1/16 steps
(15/16/31/32), the known flattening residual. Repro (200×150 canvas, white
background rect, black shape):

```
<rect x="100" y="0" width="300" height="700" transform="translate(20 110) scale(0.072 -0.072)"/>   -- 142 px > 8
<rect x="100" y="0" width="300" height="700" transform="translate(20 20) scale(0.072 0.072)"/>     -- 142 px > 8
<path d="M100 0 L400 0 L400 700 L100 700 Z" transform="translate(20 110) scale(0.072 -0.072)"/>    -- 142 px > 8
<rect x="100" y="0" width="300" height="700" transform="translate(73.352 110) scale(0.072 -0.072)"/> -- 144 px > 8
```

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T31` (branch
`t31-edge-rounding`). Files: `MicroSvg/Raster.lean` (`mkEdge`, the
scan-converter's edge setup and the row/column rounding), and
`MicroSvg/Geom.lean` **only** if the device-space point rounding
(`Mat.apply` / flatten output) turns out to be the cause. Nothing else.
Invariants in `tasks/README.md`; `Effect.lean` untouched; no `Float`.

## Method

1. Shallow-clone tiny-skia into scratch. Read `src/edge.rs` (`LineEdge::new`:
   the `fdot6::round` of `y0`/`y1` to scanlines, the `SHIFT`/`shift_aa`
   handling, the `x` initialisation at the first scanline centre
   `fdot6_to_fdot16(x0 + (dx * (top*64 + 32 - y0)) / 64)` style computation),
   `src/edge_builder.rs` (how points are scaled by `1 << SHIFT` and rounded
   before edges are built: `fdot6` conversion, `clip_shift`), and
   `src/scan/path_aa.rs` (`fill_path_impl` / `SuperBlitter`: how supersampled
   rows map to pixels and how partial coverage is accumulated, the
   `(SCALE - 1)` bias). Also `src/painter.rs` `fill_path`: check whether a
   rect-shaped path takes `fill_rect` (exact-area AA via `scan::fill_rect_aa`)
   instead of the supersampler — if so, that is a second difference to port
   for axis-aligned rectangles (detect: path is 4/5 points, axis-aligned,
   transform axis-aligned).
2. Compare against `Raster.mkEdge`/`rasterize` line by line for the top/bottom
   scanline rounding and the initial x. Our `Fx` is already FDot6 in the
   supersampled space (T1, T17 reports), so the rounding rule should be
   `(y + 32) >> 6` style, not floor — find the actual discrepancy, fix it,
   and explain it in the report with the exact expressions on both sides.
3. Byte-for-byte check on the repro set: write the four SVGs above plus a
   `pos_quad` and `flip_quad` variant with a `Q` edge into scratch, render
   with our binary and `resvg`, count pixels with max channel diff > 8 before
   and after. Required after the fix: **0 pixels > 8** on the four straight
   cases (any residual must be explained as a genuine tiny-skia difference,
   e.g. the rect fast path, and then ported too).

## Verify

- `lake build` clean.
- `python3 tests/run_tests.py` before/after: report every file's within-8;
  expected to rise on several (12_badge, 14_flower, 16_stress, 21_hairlines
  are the likely ones); **no file may drop by more than 0.02**. Files with only
  integer-aligned geometry (01, 06, 19) should be byte-identical — say which
  were.
- Corpora at fast sizes, direct route, `--compare` on
  `--corpus resvg --dir shapes --dir painting/stroke-linejoin --dir structure/transform`
  and `--corpus simple-icons --limit 400`; medians must not fall.
- `run_tiles.py` byte-identical (23 files); `run_adversarial.py` clean;
  `git diff main -- MicroSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`. If after ~40 minutes you have not found the discrepancy,
  stop, write what you ruled out (with the expressions compared) in the
  report, commit that, and say so — an Opus agent will take over.
