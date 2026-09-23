# N-rest — diagnose the 97–99% near-misses: rest  (branch `claude/research-n-rest`)

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

Write `docs/near-miss/N-rest.md` (per file: where the diff is, cause, code
location, proposed fix, size, risk; then groups by shared cause, largest
first) and `docs/near-miss/N-rest.png` (resvg | ours | diff ×4 per file, under
2 MB). Commit often; push to your branch only; no PR.

Files (within-8 at 200 px):

- `masking/clipPath/clip-path-with-transform-on-text.svg` (0.986)
