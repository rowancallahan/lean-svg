# D-paint — diagnose the 90–97% near-misses: paint  (branch `claude/research-d-paint`)

These resvg-correct files render close to resvg but not within the pass bar.
**Diagnose only.** Do not change renderer code. For each file: render ours and
resvg at 200 px, build a diff, find the root cause in our code and how
resvg/usvg 0.48.1 does it, and estimate the fix size. Group files that share
a cause. Write `docs/near-miss/D-paint.md` (per file: cause, code location,
proposed fix, size; then a table grouped by shared cause, largest group
first) and `docs/near-miss/D-paint.png` (resvg | ours | diff ×4 per file, under
2 MB). Another agent may be fixing some of these files concurrently; note it,
but diagnose anyway. Commit often; push to your branch only; no PR.

Files (within-8 at 200 px):

- `paint-servers/pattern/nested-objectBoundingBox.svg` (0.958)
- `paint-servers/pattern/recursive-on-child.svg` (0.927)
- `paint-servers/pattern/self-recursive-on-child.svg` (0.912)
- `paint-servers/pattern/self-recursive.svg` (0.912)
- `paint-servers/pattern/transform-and-patternTransform.svg` (0.906)
- `painting/fill/radial-gradient-on-text.svg` (0.946)
- `painting/stroke/radial-gradient-on-text.svg` (0.944)

## Report

Wrote `docs/near-miss/D-paint.md` and `docs/near-miss/D-paint.png` (77 KB).
No renderer code changed on this branch; `git status` stays clean of
`LeanSvg/*` diffs. Two lines in `LeanSvg/PatternRender.lean` were edited
temporarily in a throwaway `git worktree` (`/tmp/lsv-exp`, not committed,
removed with `git worktree remove` afterward) solely to measure a candidate
fix before writing it down; the removal is confirmed by `git worktree list`
showing only the main worktree.

Two shared causes found, covering all 7 files:

- **Group A** (5 pattern files): lean-svg samples a pattern's rendered
  tile with nearest-neighbour whenever the tile's combined transform is
  axis-aligned (`LeanSvg/PatternRender.lean:264`); resvg 0.48.1 always uses
  `tiny_skia::FilterQuality::Bicubic` for pattern fills, unconditionally
  (confirmed in `resvg`'s own vendored source, `crates/resvg/src/path.rs:
  61-67,101-107`). Verified non-trivial by experiment (forced
  `bicubic := true` in the throwaway worktree): fidelity got *worse*, not
  better (0.9575→0.8692, 0.9272→0.8020, 0.9122→0.7631), so lean-svg's own
  16-tap `sampleBicubic` kernel (`PatternRender.lean:106-145`) has a real,
  separate bug that must be fixed before the sampler choice can be flipped
  to match resvg. Size: MEDIUM-LARGE.
- **Group B** (2 text+radial-gradient files): usvg computes a `<text>`
  element's `objectBoundingBox` box from font ascent/descent metrics, not
  glyph ink outlines (`usvg`'s own comment at
  `crates/usvg/src/text/layout.rs:404-410`, "We have to calculate text
  bbox using font metrics and not glyph shape"); confirmed numerically via
  `usvg`'s own CLI output (`gradientTransform` matrices resolve to an
  ascent/descent box matching Noto Sans's real 1.069 em / 0.293 em metrics
  exactly, at two different font sizes). lean-svg's `tightBox`/`cmdsBox`
  (`LeanSvg/Shader.lean:997`, `LeanSvg/Svg.lean:3874`) use the ink outline
  instead, giving a vertical extent 1.7-1.9× too small and radial
  gradients that darken 1.5-2× too fast moving away from centre —
  confirmed pixel-by-pixel (matching alpha/coverage, diverging colour) at
  several sample points. Root cause and exact numbers are fully pinned
  down; fix is plumbing, not investigation. Size: MEDIUM. Same bug exists
  a second, independent time for clip-path/mask/filter bbox on text
  (`LeanSvg/Svg.lean:3866-3875`), noted but not chased further (no such
  file is on this task's list).

Full per-file writeup, code citations, and the summary table (largest
group first) are in `docs/near-miss/D-paint.md`.
