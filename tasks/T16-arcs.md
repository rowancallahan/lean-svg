# T16 — Elliptical arc commands (`A` / `a`) in path data

## Goal

The single biggest defect on real files: 2 405 of 3 461 simple-icons and
146 of 287 feather icons use arcs, and our path parser stops at the first
`A`. Implement SVG arcs by converting each to at most four cubic Béziers,
entirely in fixed point, with no `atan2`.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T16` (branch
`t16-arcs`). Files: `LeanSvg/Svg.lean` (`parsePathData` and a new arc
conversion section placed in this file, not in `Geom.lean`, which another
agent is editing). Invariants in `tasks/README.md`.

## Algorithm (decided; SVG 1.1 implementation notes §F.6.5, without angles)

Input: current point `p1`, params `rx ry φ fA fS x y` (7 numbers; `fA`/`fS`
are flags `0`/`1` and may be written without separators, e.g. `a1 1 0 01 5 5`
— the flag parser must consume exactly one character for each flag).
Endpoint `p2 = (x, y)` (relative if `a`).

1. `p1 = p2` → nothing. `rx = 0 ∨ ry = 0` → `lineTo p2`. Use `|rx|, |ry|`.
2. Rotate by `−φ` with `sinCos16 (degToRad16 φ)`: `d = (p1 − p2)/2`,
   `x1' = cos·dx + sin·dy`, `y1' = −sin·dx + cos·dy` (16.16 → `Fx`).
3. Radii correction: if `x1'²·ry² + y1'²·rx² > rx²·ry²` then
   `rx := √(x1'²·ry² + y1'²·rx²) / ry`, `ry := √(…) / rx` (in `Nat`; the
   products are large but bounded by clamped inputs; `Nat.sqrt`).
4. Centre in the rotated frame: `num = rx²ry² − rx²y1'² − ry²x1'²`
   (clamp at 0), `den = rx²y1'² + ry²x1'²` (if 0 → treat as line),
   `coef = √(num·2^32 / den)` as 16.16, sign `+` if `fA ≠ fS` else `−`;
   `cx' = coef·rx·y1'/ry`, `cy' = −coef·ry·x1'/rx`.
5. Centre in user space: `c = R(φ)·(cx', cy') + (p1 + p2)/2`.
6. Unit vectors in the ellipse's parameter space (16.16):
   `u1 = ((x1' − cx')/rx, (y1' − cy')/ry)`, `u2 = ((−x1' − cx')/rx, (−y1' − cy')/ry)`,
   each renormalised with `Fx.hypot` so rounding cannot make them non-unit.
7. Sweep: `fS = 1` means positive-angle direction. Emit at most 4 segments:
   with current `u := u1`, test whether `u2` lies within the next quarter
   turn in the sweep direction (`cross = u × u2` has the sweep's sign or is
   zero, and `dot = u · u2 ≥ 0`, and not the degenerate case where
   `u = u2` on the first step with `fA = 1`, which is a full turn: then emit
   four quarters). If yes, emit the final segment `u → u2`; otherwise emit a
   quarter `u → rot90(u)` (`rot90` in the sweep direction is a coordinate
   swap with one sign flip) and continue. Bounded `for` of 4 iterations.
8. One segment from unit vectors `a` to `b` (angle `θ ≤ 90°`) as a cubic:
   `c = a·b`, `s = |a × b|`, `t2 = s/(1 + c)` (= tan θ/2),
   `t4 = t2/(1 + √(1 + t2²))` (= tan θ/4), `k = 4·t4/3`, all 16.16 with
   `Nat.sqrt` on `2^32`-scaled values. Tangents `a⊥ = rot90(a)`,
   `b⊥ = rot90(b)` in the sweep direction. Control points in parameter
   space `a + k·a⊥` and `b − k·b⊥`; map every parameter-space point `v` to
   user space with `c + R(φ)·(rx·v.x, ry·v.y)`. The last segment's end
   point is exactly `p2` (do not recompute it), so paths stay closed.
9. Update `cur := p2`; arcs reset the smooth-curve reflection state like
   any non-`C`/`S` (resp. non-`Q`/`T`) command.

## Verify

- `python3 tests/run_tests.py`: no file changes (the corpus has no arcs;
  confirm byte-identity of all 21 renders against main's binary).
- Add `tests/svg/22_arcs.svg`: arcs with all four flag combinations, a
  rotated ellipse arc, radii too small (correction), a full-circle pair, a
  "flags without separators" path, arcs in relative form, and a rounded
  shape drawn with arcs (like an icon). Report its within-8 (target ≥ 99%).
- Corpora (fast loop, in your worktree, `--out` to a temp dir so main's
  results are not clobbered; if `tests/run_corpora.py` lacks `--fast`/`--out`
  yet, use `--limit 400` and a copy of the script):
  `python3 tests/run_corpora.py --corpus simple-icons --route direct --limit 400`
  and `--corpus feather --route direct`, before and after: report pass%
  and median within-8 for files with arcs. Target: arc files reach the
  same pass rate as non-arc files (~57% direct on simple-icons; the rest
  is T17's flattening).
- `run_tiles.py`, `run_adversarial.py` clean; `Effect.lean` untouched.

## Done when

Arc icons render like resvg (report numbers), no regressions, `## Report`
appended, committed on the branch.

## Report

### What changed

- `LeanSvg/Svg.lean`
  - new **“Elliptical arcs”** section before `## Path data`: `divRound`,
    `ArcDir`, `rot90`, `unit16`, `arcHiMax`/`clampHi`, `arcSegment`, `arcPath`.
    §F.6.5 endpoint-to-centre conversion, at most four cubic quarters, all
    integer: `Fx` for coordinates, 16.16 for directions, `Nat.sqrt` for every
    root. No `atan2`, no `Float`, no `partial`/`unsafe`/`panic!`/`!`-indexing;
    the sweep walk is a `for` over `[0:4]`.
  - `parsePathData`: `need = 7` for `a`, a flag branch that consumes **exactly
    one byte** for each of `fA`/`fS` (so `a1 1 0 011 5` parses), and an `up ==
    97` dispatch arm. Arcs fall through the existing `prevWasC/prevWasQ :=
    false`, so they reset the smooth-curve reflection state like any other
    non-`C`/`S`, non-`Q`/`T` command. `rx ry φ` are never relative; only the
    endpoint is.
- `tests/svg/22_arcs.svg` — new.
- Nothing else. `Effect.lean`, `Geom.lean` (T17) and the stroker/`Style`
  (T23) untouched.

### Numbers

`tests/run_tests.py`, 21 pre-existing files: **byte-identical** to main's
binary at natural size *and* `--width 800` (21/21 both ways, `diff -r`), so
nothing regressed. Suite goes 17/22 → 18/22; the four that still fail
(`12_badge`, `14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`)
fail identically before and after and are T17's curve flattening.

`tests/svg/22_arcs.svg`: **99.057 %** within-8 (99.894 % within-32,
`max_d` 59, 560x420) — **PASS**. With main's binary the same file scores
84.286 %. It covers all four flag combinations, three x-axis rotations
(0, −30, 62.5), a 4.5x §F.6.6 radii correction, a full circle as two
half-turn arcs in relative form, an even-odd ring whose flag pairs are
written with no separators at all (`a28,28 0 1156,0`), the §F.6.2 degenerate
forms (zero radius → line, `p1 == p2` → nothing), and a rounded icon shape
whose closing arc must land exactly on the start point.

Corpora, `--route direct`, width 96, before → after:

| corpus / slice | files | pass% before | pass% after | med within-8 before | after |
|---|---|---|---|---|---|
| simple-icons, all | 3461 | 17.6 % | **34.6 %** | – | – |
| simple-icons, has arcs | 2405 | 0.2 % | **24.8 %** | 67.665 % | **98.405 %** |
| simple-icons, no arcs | 1056 | 57.1 % | 57.1 % | 99.192 % | 99.192 % |
| simple-icons (`--limit 400`), all | 400 | 18.8 % | **35.0 %** | – | – |
| simple-icons (`--limit 400`), has arcs | 285 | 0.4 % | **23.2 %** | 66.873 % | **98.394 %** |
| simple-icons (`--limit 400`), no arcs | 115 | 64.3 % | 64.3 % | 99.316 % | 99.316 % |
| feather, all | 287 | 30.7 % | **50.2 %** | – | – |
| feather, has arcs | 146 | 0.0 % | **38.4 %** | 82.080 % | **98.682 %** |
| feather, no arcs | 141 | 62.4 % | 62.4 % | 99.316 % | 99.316 % |

`run_tiles.py`: 22/22 files, quadrant tiles stitch byte-identically.
`run_adversarial.py`: 39/39 clean, 0 violations (38/38 without the new file —
the case count scales with `tests/svg/*.svg`, so README invariant 8's
"28/28" is stale). Malformed and extreme arcs (`A` truncated, flag `2`,
radii `1e9`/`1e18`/`1e-30`, rotation `1e30`, negative radii, `p1 == p2`)
render in 0.16 s at `--width 1600` with exit 0.

### Two findings worth carrying forward

**A rounding bug the corpus caught.** The §F.6.6 radii correction must round
*down*. A corrected ellipse is one the endpoints lie exactly on, so the
centre numerator is zero and the centre is the chord's midpoint; rounding a
radius *up* by even one 1/256 px makes the numerator positive and the centre
then moves by `√(r'² − (chord/2)²)`, a square root of a tiny number. On
`tencenthy.svg` (`M12 0a1 1 0 0 1 0 24 …`, a 4.5x correction) a
ceiling-rounded radius threw the centre 0.3 user units off the chord:
91.157 % → **95.540 %** after switching to floor. `Nat` truncating
subtraction then gives the spec's clamp-at-zero for free.

**The residual is flattening, not the arc conversion.** Control run: the same
400-file sample on the **usvg route**, where usvg does the arc→cubic itself
and our renderer only ever sees cubics. Arc files there reach 31.6 % pass /
98.654 % median — so under this rasteriser the ceiling for arc files is
~32 %, not the ~57 % of non-arc files, and our own conversion costs only
0.26 median points against usvg's. 185 of 285 arc files sit between 97 % and
99 %, clustered just under the threshold. (Measured before T17 merged; worth
re-running now that it has.)

A quarter arc produces control points *identical* to `ellipsePath`'s: `k`
evaluates to exactly `kappa16` (36195) at θ = 90°, verified by `#eval
arcSegment 0 0 65536 65536 0 65536 true (65536,0) (0,65536) none`
→ `cubicTo (65536, 36195) (36195, 65536) (0, 65536)`. So the split matches
usvg's quarter-turn-with-κ scheme rather than a tolerance-driven count.

### Known limit

Near-half-turn arcs are bounded by the 1/256 px input grid, not by the
algorithm. `indigo.svg` draws its dots as `a.98.98 0 0 0 0 1.959`; on the `Fx`
grid both the radius and the half-chord land on 251/256, so the numerator is
exactly 0 and we emit an exact semicircle, where resvg's f64 puts the centre
0.031 user units off the midpoint. The square root amplifies the one-unit
quantisation, and closing it would mean carrying arc radii and endpoints
finer than 1/256 px. That file: 98.33 % direct vs 99.45 % on the usvg route.

`tests/run_corpora.py` still lacks `--fast`/`--out` (T15b), so the corpora
numbers come from a copy of it with `CORPORA_DIR` pointed at the main tree
and an `--out` override, run from a scratch directory. Nothing was written
under this worktree's `tests/out/corpora/` and the main tree was not modified.
