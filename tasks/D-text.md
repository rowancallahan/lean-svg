# D-text — diagnose the 90–97% near-misses: text  (branch `claude/research-d-text`)

These resvg-correct files render close to resvg but not within the pass bar.
**Diagnose only.** Do not change renderer code. For each file: render ours and
resvg at 200 px, build a diff, find the root cause in our code and how
resvg/usvg 0.48.1 does it, and estimate the fix size. Group files that share
a cause. Write `docs/near-miss/D-text.md` (per file: cause, code location,
proposed fix, size; then a table grouped by shared cause, largest group
first) and `docs/near-miss/D-text.png` (resvg | ours | diff ×4 per file, under
2 MB). Another agent may be fixing some of these files concurrently; note it,
but diagnose anyway. Commit often; push to your branch only; no PR.

Files (within-8 at 200 px):

- `text/alignment-baseline/middle-on-textPath.svg` (0.955)
- `text/alignment-baseline/two-textPath-with-middle-on-first.svg` (0.952)
- `text/font-variant/inherit.svg` (0.961)
- `text/font-variant/small-caps.svg` (0.961)
- `text/font-weight/bolder-with-clamping.svg` (0.962)
- `text/font-weight/lighter-with-clamping.svg` (0.959)
- `text/font-weight/lighter-without-parent.svg` (0.959)
- `text/font/font-shorthand.svg` (0.970)
- `text/lengthAdjust/spacingAndGlyphs.svg` (0.957)
- `text/lengthAdjust/text-on-path.svg` (0.964)
- `text/lengthAdjust/vertical.svg` (0.957)
- `text/lengthAdjust/with-underline.svg` (0.955)
- `text/text-anchor/on-tspan-with-arabic.svg` (0.969)
- `text/text/rotate-with-multiple-values-and-complex-text.svg` (0.927)
- `text/text/x-and-y-with-multiple-values-and-arabic-text.svg` (0.959)
- `text/text/zalgo.svg` (0.937)
- `text/textPath/dy-with-tiny-coordinates.svg` (0.939)
- `text/textPath/m-L-Z-path.svg` (0.945)
