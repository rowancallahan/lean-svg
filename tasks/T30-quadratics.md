# T30 — Native quadratic curves (`quadTo`) flattened like tiny-skia's `QuadraticEdge`  [Sonnet]

Follow-up recommended by T17 (`tasks/T17-flatten.md`, read its `## Report`
first). Today `Q`/`T` path commands are degree-elevated to cubics in
`Svg.parsePathData`, so they get the cubic subdivision rule (which has a
`+1` on the shift) and come out with more segments than resvg uses; the
one file that regressed under T17 (`15_spiral_stroke`, 119 quadratics) and
the stroked-curve icons pay for it. Fix: carry quadratics as their own
`PathCmd` constructor and flatten them with tiny-skia's quadratic rule.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T30` (branch
`t30-quads`). Files: `LeanSvg/Geom.lean` (the `PathCmd` type, `segCount`/
`flatten` section, and the bounding-box functions that match on `PathCmd`),
`LeanSvg/Svg.lean` **only** `parsePathData`'s `Q`/`T` cases (emit the new
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
  `git diff main -- LeanSvg/Effect.lean` empty.
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report` with the tables above and the exact `diff_to_shift`
  expression you ported.

## Report

### Source read

`tiny-skia` cloned shallow at `5d4754777746eef0828be166896eaf482c49f8f2` (same
commit T17 used) into scratch. The file is `src/edge.rs` (not
`path/src/edge.rs` — that path moved in this checkout), `impl QuadraticEdge`
(`new`/`new2`/`update`), plus the shared `diff_to_shift`/`cheap_distance` and
`edge_builder.rs`'s `push_quad` (`QuadraticEdge::new(points, self.clip_shift)`,
confirming `shift_aa = clip_shift = 2`, the same value the cubic path uses
literally).

`QuadraticEdge::new2`'s segment-count block, ported verbatim:

```rust
let dx = (left_shift(x1, 1) - x0 - x2) >> 2;
let dy = (left_shift(y1, 1) - y0 - y2) >> 2;
shift = diff_to_shift(dx, dy, shift);   // shift_aa = clip_shift = 2, threaded through
if shift == 0 { shift = 1; } else if shift > MAX_COEFF_SHIFT { shift = MAX_COEFF_SHIFT; }
let curve_count = 1 << shift;           // no "+1" — that's the cubic rule
```

`diff_to_shift`/`cheap_distance` are exactly what T17 already ported into
`diffToShift`/`cheapDistance` for `shift_aa = 2`, so no new copy was needed —
`QuadraticEdge::new` and `CubicEdge::new` are both called with the builder's
`clip_shift = 2`, and the cubic path's `diff_to_shift(dx, dy, 2)` uses the same
literal. The exact `diffToShift` expression (already in `Geom.lean`, reused
unchanged):

```
diffToShift dx dy = bitLength ((cheapDistance dx dy + 16) / 32) / 2
cheapDistance dx dy = let dx := |dx|; dy := |dy|; if dx > dy then dx + dy/2 else dy + dx/2
```

**One deliberate deviation from this task file's step 4 paraphrase, resolved
by reading the source as instructed.** The spec says "`if shift == 0` →
line"; the actual Rust bumps `shift` to `1` (`curve_count = 2`), not down to a
1-segment line — the comment ("need at least 1 subdivision for our bias
trick") is about `curve_shift = shift - 1` underflowing tiny-skia's `u8` in
its forward-difference walker, an implementation artifact we don't have since
we evaluate the quadratic exactly at `k/n`. Since resvg's actual pixels come
from the bumped (2-segment) path, `segCountQuad` ports the bump literally
(`if s == 0 then 1 else Nat.min maxCoeffShift s`, giving `n = 2^shift ≥ 2`),
not the paraphrase's `n = 1`. Confirmed against the oracle below, not assumed:
the 119 quadratics in `15_spiral_stroke` sum to exactly **532** flattened
segments under this rule, which is the exact `QuadraticEdge` count T17's
report already measured from resvg's real output for that file.

### What changed (files)

`LeanSvg/Geom.lean` (+81/−5 lines, in the `PathCmd` type and the
`segCount`/`cubicAt`/`flatten` and `Box`/`ctrlBoxMeets` sections only):
- `PathCmd` gets a new constructor `quadTo (c p : Pt)`.
- Added `quadDeltaFromLine`, `segCountQuad`, `quadAt` (mirroring
  `cubicDeltaFromLine`/`segCount`/`cubicAt`, reusing the existing
  `diffToShift`/`cheapDistance`/`bitLength`/`maxCoeffShift` unchanged).
- `flatten` gets a `.quadTo c p` case: `n := segCountQuad ctm pt c p`, then
  `quadAt pt c p k n` for `k` in `[1, n]`, same shape as the `.cubicTo` case.
- `ctrlBoxMeets` gets a matching `.quadTo c p` case covering `c` and `p`
  through the control-polygon box, same shape as `.cubicTo`.
- The `ctrlBoxMeets` doc comment is reworded to say "cubic and quadratic
  control points" instead of "cubic control points"; no behavioural change.

`LeanSvg/Svg.lean` (`parsePathData`'s `Q`/`T` case only, −5/+1 lines): the
degree-elevation to `c1`/`c2` is deleted; the case now pushes `.quadTo qc q`
directly, where `qc` is the already-computed reflection/absolute control
point used for `T`'s "reflect the previous quadratic control point" rule
(unchanged). `lastQ`/`prevWasQ` bookkeeping is untouched.

Nothing else in the repo changed: `git status --porcelain` shows only these
two files. The two `match` sites the compiler could have flagged as
non-exhaustive were exactly these two (`flatten`, `ctrlBoxMeets`) — grepped
for every use of `PathCmd` in the tree first to confirm there are no others
(`Svg.ellipsePath`, `Svg.rectPath`, `Svg.arcPath`, `Svg.polyPath` only
*construct* `PathCmd` values, never match on them). `Font.lean` (T25) does not
exist yet in this worktree (it is in flight in `.worktrees/T25`); per the
task's note, it will keep emitting cubics for now, and **could emit
`quadTo` directly later** since TrueType glyph outlines are natively
quadratic — left for whoever picks that up.

`lake build`: clean, 26/26 jobs, no errors. Rebuilt from a `touch` of both
changed files to rule out a stale-warning cache: `grep -i "warn\|error"` on
the full rebuild output is empty. Invariants hold: no `partial`/`unsafe`/
`@[extern]`/`panic!`/`!`-index, no `Float`, `Fx` still `Int`, every loop a
`for` over a constant or input-sized range, `segCountQuad`'s exponent capped
at 6 exactly as `segCount`'s is.

### `run_tests.py`, before (main-tree binary, copied to scratch first) / after

22 files (`22_arcs` was added by T16, after T17's report table). Only the
three files with `Q`/`T` in their `d` attributes move; all 19 others are
**byte-identical** (`md5` of every `tests/out/*_ours.png`, before vs. after,
matches file-for-file except these three).

| file | within% before | after | Δ |
|---|---|---|---|
| 01_triangle | 100.000 | 100.000 | 0.000 |
| 02_rect_circle | 99.997 | 99.997 | 0.000 |
| 03_curves | 99.525 | **99.855** | **+0.330** |
| 04_stroke | 99.965 | 99.965 | 0.000 |
| 05_transform | 99.987 | 99.987 | 0.000 |
| 06_evenodd | 100.000 | 100.000 | 0.000 |
| 07_opacity | 99.885 | 99.885 | 0.000 |
| 08_group_inherit | 99.992 | 99.992 | 0.000 |
| 09_viewbox | 99.963 | 99.963 | 0.000 |
| 10_polygon_star | 99.823 | 99.823 | 0.000 |
| 11_style_attr | 99.983 | 99.983 | 0.000 |
| 12_badge | 98.277 | **98.561** | **+0.284** |
| 13_gear_evenodd | 99.368 | 99.368 | 0.000 |
| 14_flower_transforms | 97.814 | 97.814 | 0.000 |
| 15_spiral_stroke | 97.252 | **97.480** | **+0.228** |
| 16_stress_2000 | 97.481 | 97.481 | 0.000 |
| 17_koch_snowflake | 99.222 | 99.222 | 0.000 |
| 18_rose_lissajous | 99.690 | 99.690 | 0.000 |
| 19_sierpinski | 100.000 | 100.000 | 0.000 |
| 20_function_plot | 99.777 | 99.777 | 0.000 |
| 21_hairlines | 99.884 | 99.884 | 0.000 |
| 22_arcs | 99.214 | 99.214 | 0.000 |

18/22 pass before and after (same four failures). No file drops — the
`≤ 0.02` regression budget was not needed. `15_spiral_stroke` rises as
expected. **`20_function_plot` does not rise, because it contains no `Q`/`T`
commands at all** (`grep` on its `d`/`points` data confirms zero — it is
polylines and a `<rect>`); the task file's expectation here was wrong about
that file's contents, same kind of stale assumption T17's report flagged for
files 13/18.

**Segment-count check against the oracle (measured, not assumed).** Reimplemented
`segCountQuad` in Python over `15_spiral_stroke`'s 119 quadratics (natural
size, identity `ctm`, so device `Fx` = parsed `Fx` exactly):

| rule | total segments |
|---|---|
| pre-T17 `√(2·L_px)+1` on the degree-elevated cubic | 685 |
| T17's `CubicEdge` rule on the degree-elevated cubic (this branch's parent) | 752 |
| **this task: `QuadraticEdge` rule on the native quad** | **532** |

532 is exactly the number T17's report attributed to "what resvg actually
does" for this file — the fix lands on the oracle's own count, not just
closer to it.

### Corpora, usvg route, `--fast` (before: scratch copy of the main-tree
binary; after: this branch's binary; `--compare` against the before CSV)

```
python3 tests/run_corpora.py --fast --no-worst --corpus simple-icons --route usvg --limit 400 --out <scratch>/before
python3 tests/run_corpora.py --fast --no-worst --corpus feather --route usvg --out <scratch>/before
# then --out <scratch>/after --compare <scratch>/before/<corpus>_usvg.csv
```

| corpus | files | pass% before | pass% after | median within-8 before | after |
|---|---|---|---|---|---|
| simple-icons (usvg, `--limit 400`) | 400 | 77.00 | **77.25** | 99.414 | 99.414 |
| feather (usvg, all) | 287 | 31.36 | 31.36 | 98.462 | 98.462 |

Neither corpus's pass% or median falls. simple-icons: 1 file newly passing
(`protools.svg`, 95.630% → 99.487%, +3.857), 0 newly failing, 399 unchanged
(the harness's own "moved by > 0.1 points" filter shows only this one file —
usvg's `Q` output is otherwise rare enough in this random 400-file sample that
most files see no `Q`/`T` at all). feather: 0 files moved by more than 0.1
points; feather is a stroke corpus dominated by the stroker gap T17 already
documented, not by flattening.

### Tiles and adversarial

- `python3 tests/run_tiles.py`: **22/22 files, all `exact / clear / exact`** —
  every quadrant tile stitches byte-identically to the full render, including
  the three files with `Q`/`T`.
- `python3 tests/run_adversarial.py`: **39/39 cases clean, 0 with violations**.
  (The task file's "must stay 28/28" is stale — this branch's harness already
  runs 39 cases, up from whatever count the task was written against; all 39
  passed clean.)
- `git diff main -- LeanSvg/Effect.lean`: empty.

### Timing (median of 3, same machine, before → after)

| file | size | before | after |
|---|---|---|---|
| 03_curves | natural | 6.2 ms | 5.4 ms |
| 03_curves | `--width 800` | 22.1 ms | 22.0 ms |
| 12_badge | natural | 18.6 ms | 18.4 ms |
| 12_badge | `--width 800` | 94.2 ms | 92.7 ms |
| 15_spiral_stroke | natural | 29.4 ms | 27.6 ms |
| 15_spiral_stroke | `--width 800` | 135.3 ms | 136.0 ms |

No regression; if anything a hair faster on quad-heavy files, since native
quadratics no longer pay the cubic rule's `+1` shift of headroom on top of
degree elevation.

### Harness status

* `lake build` — clean, no errors, no new warnings.
* `python3 tests/run_tests.py` — 18/22 before, 18/22 after, same four
  failures; three files rise, nineteen are byte-identical.
* `python3 tests/run_adversarial.py` — 39/39 clean, 0 violations.
* `python3 tests/run_tiles.py` — 22/22 files stitch byte-identically.
* `LeanSvg/Effect.lean` byte-identical to `main`; the stroker/`dashPoly`
  section of `Geom.lean`, `interpret`, `applyProp`/`Style`, and the arc code
  are untouched.
