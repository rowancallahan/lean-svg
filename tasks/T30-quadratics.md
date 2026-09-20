# T30 — Native quadratic curves (`quadTo`) flattened like tiny-skia's `QuadraticEdge`  [Sonnet]

Follow-up recommended by T17 (`tasks/T17-flatten.md`, read its `## Report`
first). Today `Q`/`T` path commands are degree-elevated to cubics in
`Svg.parsePathData`, so they get the cubic subdivision rule (which has a
`+1` on the shift) and come out with more segments than resvg uses; the
one file that regressed under T17 (`15_spiral_stroke`, 119 quadratics) and
the stroked-curve icons pay for it. Fix: carry quadratics as their own
`PathCmd` constructor and flatten them with tiny-skia's quadratic rule.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T30` (branch
`t30-quads`). Files: `MicroSvg/Geom.lean` (the `PathCmd` type, `segCount`/
`flatten` section, and the bounding-box functions that match on `PathCmd`),
`MicroSvg/Svg.lean` **only** `parsePathData`'s `Q`/`T` cases (emit the new
constructor instead of elevating) and any other exhaustive `match` on
`PathCmd` the compiler reports. Do not touch the stroker or `dashPoly`
(T23 is editing that section of `Geom.lean`), `interpret` (T27/T29),
`applyProp`/`Style` (T24a), the arc code (just merged), or other modules.
Invariants in `tasks/README.md`.

## The rule

Port `QuadraticEdge::new` from tiny-skia `src/edge.rs`
(fetch https://raw.githubusercontent.com/linebender/tiny-skia/master/path/src/… —
locate the file with the GitHub API or clone shallowly into your scratch
dir; do not add it to the repo). In our units the control points in device
space are already FDot6-in-supersampled-space (`Fx` = 1/256 px = tiny-skia's
FDot6 at SHIFT=2; see T1 and T17's report). The steps, mirroring T17's
cubic port:

1. `dx = ((2·x1 − x0 − x2) >> 2)` per axis (Skia: `(SkLeftShift(x1,1) - x0 - x2) >> 2`), then `|dx|`, `|dy|`.
2. `dist = cheap_distance(dx, dy)` = `max + min/2`.
3. `shift = diff_to_shift(dist, shiftAA = 2)`: `dist = (dist + (1 << 4)) >> (3 + shiftAA)`, then `(32 − leading_zeros(dist)) >> 1`. Check the exact expression in the source.
4. `if shift == 0 → line`; `shift > MAX_COEFF_SHIFT (6) → 6`. Segment count `2^shift`. No `+1` (that is the cubic rule).
5. Samples at `t = k / 2^shift`, exact Bernstein evaluation with the last point exact, as `flatten` does for cubics.

Bounding boxes: the quadratic's control polygon (T10's `ctrlBoxMeets`
style). `Svg.ellipsePath`, `rectPath` and the arc code keep emitting cubics.
`Font.lean` (T25, in flight) will emit cubics too; note in the report that
it could emit quadratics directly later (TrueType outlines are quadratic).

## Verify

- `lake build` clean; no exhaustive-match warnings.
- `python3 tests/run_tests.py` before (main binary) and after: no file's
  within-8 may drop by more than 0.02 points; `15_spiral_stroke` and
  `20_function_plot` are expected to rise; all files without `Q`/`T` must be
  byte-identical (check with a hash of the PNGs, e.g. `md5 tests/out/*.png`
  before and after).
- Corpora, usvg route, fast sizes, before/after with `--compare`:
  ```
  python3 tests/run_corpora.py --fast --no-worst --corpus simple-icons --route usvg --limit 400 --out <scratch>/before
  python3 tests/run_corpora.py --fast --no-worst --corpus feather --route usvg --out <scratch>/before
  ```
  then the same with `--out <scratch>/after --compare <scratch>/before/<corpus>_usvg.csv`.
  Report pass% and median within-8 before/after; neither may fall. (usvg
  emits `Q` for quadratics, so these are the files that change.)
- `python3 tests/run_tiles.py` all byte-identical; `python3 tests/run_adversarial.py` clean;
  `git diff main -- MicroSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report` with the tables above and the exact `diff_to_shift`
  expression you ported.
