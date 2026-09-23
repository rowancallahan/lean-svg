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
