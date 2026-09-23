# D-structure — diagnose the 90–97% near-misses: structure  (branch `claude/research-d-structure`)

These resvg-correct files render close to resvg but not within the pass bar.
**Diagnose only.** Do not change renderer code. For each file: render ours and
resvg at 200 px, build a diff, find the root cause in our code and how
resvg/usvg 0.48.1 does it, and estimate the fix size. Group files that share
a cause. Write `docs/near-miss/D-structure.md` (per file: cause, code location,
proposed fix, size; then a table grouped by shared cause, largest group
first) and `docs/near-miss/D-structure.png` (resvg | ours | diff ×4 per file, under
2 MB). Another agent may be fixing some of these files concurrently; note it,
but diagnose anyway. Commit often; push to your branch only; no PR.

Files (within-8 at 200 px):

- `masking/mask/with-opacity-1.svg` (0.952)
- `structure/svg/mixed-namespaces.svg` (0.965)
- `structure/systemLanguage/on-tspan.svg` (0.952)
- `structure/transform-origin/on-text-path.svg` (0.962)
