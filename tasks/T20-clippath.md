# T20 — `clipPath`  [Opus]

PLAN C26 (C27 optional). Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T20`
(branch `t20-clippath`). Builds on the defs table from T18 (merge main first
if T18 has landed; if not, add a minimal `clipPath` entry to the same table
shape and expect a merge task). Files: `MicroSvg/Svg.lean` (defs entry for
`clipPath` and its children; `clip-path` property on `Style`), new
`MicroSvg/Clip.lean` (build a coverage mask from a clipPath), `MicroSvg/Render.lean`
(multiply the shape's coverage by the clip mask before painting; group
`clip-path` applies to each descendant shape — note the AA-edge divergence
from resvg's layer clip in the report; T22's layers will fix that later).
Invariants in `tasks/README.md`; `Effect.lean` untouched; no `Float`.

## Behaviour (usvg `crates/usvg/src/parser/clippath.rs`, resvg `clip.rs`)

- `clipPath` children: shapes, `text` (if T36 has landed, else skipped and
  reported), `use` (skip, report); each child's own `clip-path` and
  transform apply; the clip region is the union of the children's fills
  (each with its `clip-rule`), rasterised with the normal AA scan converter
  into a `Mask` in device space; `clipPathUnits` userSpaceOnUse (default)
  or objectBoundingBox (scaled by the clipped element's user-space bbox,
  same bbox rule as T18 gradients); `transform` on the `clipPath` element;
  a `clip-path` on the `clipPath` element itself intersects (multiply).
  Invalid references → element not rendered (usvg drops it); self/cyclic
  references → dropped; nesting fuel 8.
- Coverage combine: `cov' = cov × clip / covFull` with the same rounding as
  tiny-skia's mask multiply (check `Mask::apply` / the pipeline's
  `mask_u8`), so tiles stay byte-identical.

## Verify

- `lake build` clean; `git diff main -- MicroSvg/Effect.lean` empty.
- New `tests/svg/27_clip.svg` ≥ 99% within 8 vs resvg.
- Corpora fast sizes, direct route, `--compare`: `--dir masking/clipPath
  --dir masking/clip-rule --dir masking/clip`. Target clipPath ≥ 30/52; one
  line per remaining failure grouped by cause (text clips, `use`, layers).
- `run_tests.py` byte-identical on existing files; `run_tiles.py`
  byte-identical incl. the new file; `run_adversarial.py` clean plus: a
  clipPath referencing itself, an 8-deep chain, 10 000 clip children, a clip
  on every one of 100 000 shapes.
- Commit (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.
