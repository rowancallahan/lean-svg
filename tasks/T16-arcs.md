# T16 — Elliptical arc commands (`A` / `a`) in path data

## Goal

The single biggest defect on real files: 2 405 of 3 461 simple-icons and
146 of 287 feather icons use arcs, and our path parser stops at the first
`A`. Implement SVG arcs by converting each to at most four cubic Béziers,
entirely in fixed point, with no `atan2`.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T16` (branch
`t16-arcs`). Files: `MicroSvg/Svg.lean` (`parsePathData` and a new arc
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
