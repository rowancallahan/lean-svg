# T23 — `stroke-dasharray` and `stroke-dashoffset`

## Goal

23 resvg-suite files at 0–29%. Implement dashing on flattened polylines
before stroking.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T23` (branch
`t23-dashes`). Files: `LeanSvg/Geom.lean` **stroking section** (append a
new `dashPoly`; do not modify `segCount`/`cubicAt`/`flatten`, which another
agent is editing), `LeanSvg/Svg.lean` (`Style` fields `dashes : Array Fx`,
`dashOffset : Fx`; `applyProp` for `stroke-dasharray` (list of lengths,
`none`, percentages rejected → none) and `stroke-dashoffset`; inheritance
like the other stroke props) — keep the `Svg.lean` edits to those lines
only, since T16 is editing `parsePathData` in the same file — and
`LeanSvg/Render.lean` (`drawShape`: apply `dashPoly` to each flattened
`Poly` before `strokePoly` when the pattern is non-empty).

## Algorithm (decided, SVG 1.1 §11.4)

- Pattern: if any value is negative or the list is empty → solid. Odd
  count → repeat the list once. Sum `S`; if `S ≤ 0` → solid.
- Offset: `off = dashOffset mod S` (Euclidean, so negative offsets work).
  Walk the pattern to find the starting dash index and the remaining
  length in it; the first entry is "on".
- Walk each polyline's segments (user space, `Fx`), splitting at dash
  boundaries using `Fx.hypot` for lengths and linear interpolation for the
  split points (`Int.ediv`). Emit each "on" run as an *open* `Poly` (closed
  subpaths are dashed as open paths starting at their first point, and the
  pattern continues across the closing segment). Caps apply to every dash
  end (that is what `strokePoly` already does for open polylines).
- Bound the work: if the subpath's total length divided by `S` times the
  pattern length would exceed 100 000 dashes, draw the subpath solid
  instead (report this rule in the docs). Every loop is a `for` over the
  segments and over a computed dash count bounded by that cap.
- Zero-length dashes with round/square caps must still emit a dot: emit a
  single-point `Poly` (the stroker already handles dots).
- Percent and `em` values: reject (solid), as `parseLength` does.

## Verify

- `python3 tests/run_tests.py` unchanged (no corpus file uses dashes;
  confirm byte-identity of all 21 renders against main's binary).
- Add `tests/svg/23_dashes.svg`: several patterns (even/odd counts, zero
  entries, offsets positive/negative/larger than the sum), on open and
  closed paths, with each cap style, on a curve and on a circle, plus a
  dashed hairline. Report within-8 (target ≥ 99%).
- Corpora: `python3 tests/run_corpora.py --corpus resvg --route direct
  --dir painting/stroke-dasharray --dir painting/stroke-dashoffset` (use
  `--out` temp or a script copy if the flags are missing) before/after;
  report pass% (target: most of the 23 pass; list any that don't and why).
- `run_tiles.py`, `run_adversarial.py` clean; `Effect.lean` untouched.

## Done when

Dash tests pass, no regressions, report appended, committed on the branch.

## Report

### What changed

- `LeanSvg/Geom.lean` — new `## Dashing` section at the end (after `strokePoly`,
  nothing above it touched): `maxDashes`, `dashPattern`, `dashPoly`, `dashPolys`.
- `LeanSvg/Fixed.lean` — `parseAbsLength` / `parseAbsLengthAll` /
  `parseAbsLengthList` next to `parseLength`.  Absolute units only: `%` was
  already rejected, `em`/`ex` now are too (`parseLength` resolves them against a
  fixed 16 px font that is not the document's).  The list parser is
  all-or-nothing, so one bad item means "not dashed".
- `LeanSvg/Svg.lean` — `Style.dashes : Array Fx` and `Style.dashOffset : Fx`
  plus the two `applyProp` cases, and nothing else (8 added lines, 0 changed),
  so T16's `parsePathData` work merges cleanly.  Inheritance is the `Style`
  copy every other stroke property already gets.
- `LeanSvg/Render.lean` — one line in `drawShape`, in the stroke branch only:
  the flattened polys are dashed before both the hairline and the outline path,
  so a dashed hairline dashes too.  The fill still uses the undashed polys.
- `tests/svg/23_dashes.svg` — new.

`Effect.lean` untouched.  `lake build` clean, no warnings.

### Algorithm notes (deviations from the task's sketch, all measured)

The task's sketch was followed except where resvg was measured doing something
else.  Straight-line dashing is **byte-identical** to resvg for every phase case
probed (even/odd counts, offsets 0/positive/negative/past the sum, zero
entries, hairlines), which is what pinned these down:

1. **Initial entry** is Skia's `phase > gap || (phase == gap && gap)`, not a
   plain `phase >= gap`.  The difference is only visible with a zero entry: at
   offset 0 `"0 26"` must dot the start point (resvg does), while `"10 20"` at
   offset 10 must *not* (resvg does not).
2. **Closed subpaths merge the first dash into the last.**  The sketch said to
   dash a closed subpath as an open path starting at its first point; resvg
   (Skia's `SkDashPath::InternalFilter`) defers the initial dash and re-emits it
   at the end, so the start point carries a join rather than two caps.  Without
   this a dashed `<rect>` loses the outer quadrant of its first corner: 64 px at
   `max_d` 255 on a 16 px stroke.  With it, dashed closed rects and `Z` paths
   are byte-identical to resvg.  A zero-length initial dash is not deferred
   (Skia's `initialDashLength > 0`), which is what keeps `0-n-with-*-caps`
   exact.
3. **A boundary exactly on the subpath's last point starts nothing** (Skia's
   `while distance < length`), or a 160 px line dashed `"10 10"` grows a
   spurious dot at its far end.
4. **A zero-length subpath is dropped when dashing**, not drawn as a dot:
   tiny-skia's `ContourMeasureIter` skips it, so resvg draws nothing for
   `d="M 200 200 L 200 200"` with a dasharray, even with round caps.  Undashed,
   `strokePoly` still draws that dot.
5. `maxDashes = 100000`: if `total_length * pattern_length > maxDashes * sum`
   the subpath is drawn solid.  `stroke-dasharray="0.01"` on a 1194 px circle
   hits it (renders solid in 0.00 s); `"0.004 0.004"` on a 380 px line stays
   just under it and takes 0.25 s for ~95 000 dashes.

### Numbers

`python3 tests/out/run_corpora_dirs.py --corpus resvg --route direct --dir
painting/stroke-dasharray --dir painting/stroke-dashoffset` (a wrapper in the
gitignored `tests/out/` that adds `--dir`/`--out`/`--corpora-dir` to
`run_corpora.py`, which on this branch has none of them; same width 200, same
metric.  Drop it once T15b's flags land):

| | before | after |
|---|---|---|
| dash directories, direct route | **5/23 = 21.7 %** | **11/23 = 47.8 %** |

Now passing that did not: `0-n-with-butt-caps` (76.0 → 100.0), `-round-caps`
(84.3 → 99.4), `-square-caps` (88.0 → 100.0), `even-count` (92.3 → 99.1),
`multiple-subpaths` (97.6 → 100.0), `on-a-circle` (92.7 → 99.1).  No file
regressed; `n-0` went 99.25 → 99.75.

The 12 still failing, with reasons:

- **9 are circle files held back by curve flattening, not by dashing** —
  `comma-ws-separator` 98.89, `odd-count` 98.86, `ws-separator` 98.84,
  `mm-units` 98.15 (dasharray) and all four of `default`, `em-units`,
  `mm-units`, `negative-value`, `px-units` 98.84–98.88 (dashoffset).  The same
  r=70 circle with the dasharray *removed* scores **98.14 %**, i.e. worse than
  any of them, and at `--width 800` (where `segCount` subdivides four times
  finer relative to the shape) all nine score 99.60–99.71 % and would pass.
  T17 (F2, tiny-skia cubic subdivision) is what moves these.
- **`stroke-dasharray/em-units` 95.06** — `2em 1em` with `font-size="20"`.
  Rejected → solid, as the task specified; there is no font size in `Style` to
  resolve `em` against, and `parseLength`'s fixed 16 px would give 32/16 where
  resvg gives 40/20.  Needs the `font-size` part of T24.
- **`percent-units` 91.58 (dasharray) and 91.80 (dashoffset)** — rejected →
  solid / offset 0, as specified.  resvg resolves them against the viewport
  diagonal `sqrt((w²+h²)/2)` = 200 here, so this needs a viewport-aware length
  in `applyProp`, which the parser deliberately does not have.
- `stroke-dashoffset/em-units` is **not** hurt by the `em` rejection: `1.5em` =
  30 = the pattern sum, so resvg's phase is 0 too; it fails for the flattening
  reason above and passes at `--width 800`.

`python3 tests/run_tests.py`: **18/22 pass** (was 17/21).  Every one of the 21
pre-existing files has identical `exact% / within% / max_d / mean_abs` to the
pre-change baseline, and their renders are **byte-identical** — 42/42 SHA-256
matches over the 21 files at natural size and `--width 800`, against the binary
built at the branch point.  The 4 failures are the pre-existing curve ones
(12, 14, 15, 16).

`tests/svg/23_dashes.svg` (400×400, new): **99.284 % exact, 99.362 % within-8**,
`max_d` 94, PASS.  It covers every cap style, even/odd counts, zero entries
(dots and `N 0`), offsets 0 / positive / negative / past the sum, open and
closed subpaths (rect, polygon, `Z` path, each join style), a cubic and a
circle, four dashed hairlines including a closed one and a 0.5 px width, a
dashed group under `translate/rotate/scale`, and the three "not dashed" forms
(`none`, a negative entry, a zero sum).  Its residual is the known stroker
approximations: round-cap dots are `circlePoly` 16-gons and the curve/circle
carry the flattening error — the straight-line dashing in it is exact.

`python3 tests/run_adversarial.py`: **39/39 clean, 0 violations** (38 before;
the extra case is the generated `truncated_23_dashes.svg`).
`python3 tests/run_tiles.py`: **22/22 files stitch byte-identically**, including
`23_dashes`, so dashing is viewport- and thread-independent.

### Known divergences from resvg (all outside the corpus, none in SVG's grammar)

- `stroke-dasharray="7 abc 3"`: we drop the whole list (SVG 1.1 error handling)
  and draw solid; svgtypes keeps the `[7]` prefix, so resvg dashes 7/7.
- `stroke-dashoffset="999999999"`: our `Fx` clamp at 2^30 leaves phase 4 px,
  resvg's `f32` rounds the literal to 1e9 and leaves phase 0.  Neither is
  "right"; both are artefacts of the number type.
- Patterns finer than one `Fx` unit (1/256 px) quantise: `"0.01 0.01"` becomes
  3/256 px per entry and the phase walks away from resvg's over a long path.
