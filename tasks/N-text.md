# N-text — diagnose the 97–99% near-misses: text  (branch `claude/research-n-text`)

Read the Conduct section at the top of `tasks/README.md` first. Setup:
`bash scripts/cloud-setup.sh` then `export PATH=$HOME/.elan/bin:$PATH`.

These resvg-correct files are 97–99% within tolerance of resvg, just under
the 99% pass bar. **Diagnose only; do not change renderer code.** Usually
this is antialiasing, rounding, a slightly different curve flattening or
glyph position, or one small wrong region. For each file: render ours and
resvg at 200 px, build a diff and find *where* the differing pixels are (edge
AA only? a shifted glyph? one region?), find the root cause in our code, and
how resvg/tiny-skia/usvg 0.48.1 do it. Group files sharing a cause; say for
each group whether a fix could change pixels on currently-passing files (the
tiny-skia rasterizer port in `LeanSvg/Raster.lean` is load-bearing).

Write `docs/near-miss/N-text.md` (per file: where the diff is, cause, code
location, proposed fix, size, risk; then groups by shared cause, largest
first) and `docs/near-miss/N-text.png` (resvg | ours | diff ×4 per file, under
2 MB). Commit often; push to your branch only; no PR.

Files (within-8 at 200 px):

- `text/font-family/font-list.svg` (0.982)
- `text/font-family/source-sans-pro.svg` (0.982)
- `text/font-kerning/arabic-script.svg` (0.981)
- `text/font-stretch/extra-condensed.svg` (0.974)
- `text/font-stretch/inherit.svg` (0.974)
- `text/font-stretch/narrower.svg` (0.974)
- `text/letter-spacing/mixed-scripts.svg` (0.986)
- `text/letter-spacing/on-Arabic.svg` (0.987)
- `text/text-decoration/underline-with-rotate-list-4.svg` (0.986)
- `text/text-rendering/optimizeSpeed.svg` (0.989)
- `text/text-rendering/with-underline.svg` (0.985)
- `text/text/bidi-reordering.svg` (0.982)
- `text/text/complex-graphemes.svg` (0.981)
- `text/text/escaped-text-4.svg` (0.977)
- `text/text/fill-rule=evenodd.svg` (0.971)
- `text/text/ligatures-handling-in-mixed-fonts-1.svg` (0.989)
- `text/text/ligatures-handling-in-mixed-fonts-2.svg` (0.973)
- `text/text/real-text-height.svg` (0.989)
- `text/textLength/arabic-with-lengthAdjust.svg` (0.971)
- `text/textLength/arabic.svg` (0.981)
- `text/textPath/with-underline.svg` (0.980)
- `text/tspan/bidi-reordering.svg` (0.978)
- `text/writing-mode/arabic-with-rl.svg` (0.981)
- `text/writing-mode/mixed-languages-with-tb-and-underline.svg` (0.984)
- `text/writing-mode/mixed-languages-with-tb.svg` (0.980)
