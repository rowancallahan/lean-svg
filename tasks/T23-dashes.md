# T23 — `stroke-dasharray` and `stroke-dashoffset`

## Goal

23 resvg-suite files at 0–29%. Implement dashing on flattened polylines
before stroking.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T23` (branch
`t23-dashes`). Files: `MicroSvg/Geom.lean` **stroking section** (append a
new `dashPoly`; do not modify `segCount`/`cubicAt`/`flatten`, which another
agent is editing), `MicroSvg/Svg.lean` (`Style` fields `dashes : Array Fx`,
`dashOffset : Fx`; `applyProp` for `stroke-dasharray` (list of lengths,
`none`, percentages rejected → none) and `stroke-dashoffset`; inheritance
like the other stroke props) — keep the `Svg.lean` edits to those lines
only, since T16 is editing `parsePathData` in the same file — and
`MicroSvg/Render.lean` (`drawShape`: apply `dashPoly` to each flattened
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
