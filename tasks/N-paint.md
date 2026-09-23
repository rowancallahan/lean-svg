# N-paint — diagnose the 97–99% near-misses: paint  (branch `claude/research-n-paint`)

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

Write `docs/near-miss/N-paint.md` (per file: where the diff is, cause, code
location, proposed fix, size, risk; then groups by shared cause, largest
first) and `docs/near-miss/N-paint.png` (resvg | ours | diff ×4 per file, under
2 MB). Commit often; push to your branch only; no PR.

Files (within-8 at 200 px):

- `paint-servers/pattern/out-of-order-referencing.svg` (0.989)
- `paint-servers/pattern/tiny-pattern-upscaled.svg` (0.979)
- `painting/context/in-marker.svg` (0.980)
- `painting/context/in-nested-marker.svg` (0.972)
- `painting/context/in-nested-use-and-marker.svg` (0.980)
- `painting/context/with-gradient-on-marker.svg` (0.984)
- `painting/context/with-text.svg` (0.970)
- `painting/marker/marker-on-circle.svg` (0.985)
- `painting/paint-order/fill-markers-stroke.svg` (0.988)
- `painting/paint-order/markers-stroke.svg` (0.983)
- `painting/paint-order/markers.svg` (0.983)
- `painting/stroke-dasharray/comma-ws-separator.svg` (0.989)
- `painting/stroke-dasharray/em-units.svg` (0.987)
- `painting/stroke-dasharray/mm-units.svg` (0.981)
- `painting/stroke-dasharray/odd-count.svg` (0.989)
- `painting/stroke-dasharray/ws-separator.svg` (0.988)
- `painting/stroke-dashoffset/default.svg` (0.988)
- `painting/stroke-dashoffset/em-units.svg` (0.988)
- `painting/stroke-dashoffset/mm-units.svg` (0.989)
- `painting/stroke-dashoffset/negative-value.svg` (0.989)
- `painting/stroke-dashoffset/percent-units.svg` (0.989)
- `painting/stroke-dashoffset/px-units.svg` (0.989)
- `shapes/path/M-C-S.svg` (0.990)
- `shapes/path/M-S-S.svg` (0.990)
