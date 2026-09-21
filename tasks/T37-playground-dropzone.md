# T37 — Playground: drop an SVG, render with microsvg, resize, compare  [Sonnet]

Python/JS only. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T37`
(branch `t37-dropzone`). Files: `playground/server.py`, a new
`playground/drop.html` (linked from `playground/index.html` with one line).
No Lean changes.

## Deliverable

`playground/drop.html`, served by the existing playground server:

- A drop zone (and a file picker, and a paste box for SVG text). Dropping an
  `.svg` renders it through `.lake/build/bin/microsvg` via a new `POST
  /api/render` endpoint (`{svg, width, background?}` → PNG bytes or
  `{error, stderr}`); render size follows a width slider (64–2000 px) and
  re-renders on release; a "fit to pane" button sets the width to the
  displayed box. Show render time and exit code; if the renderer errors,
  show the exact error text (this is a feature: safe rejection is visible).
- A "compare with resvg" toggle: the server also runs `resvg` (same width,
  fonts pinned with `--skip-system-fonts --use-fonts-dir
  tests/corpora/resvg-test-suite/fonts` when that directory exists) and the
  page shows ours | resvg | diff (×8) with exact / within-8 percentages
  computed server-side with Pillow (reuse `tests/run_tests.py`'s compare if
  importable).
- A gallery strip of the last 12 dropped files (client-side only, object
  URLs) to click back through.
- Limits in the server: SVG ≤ 8 MB, width ≤ 4096, subprocess timeout 20 s,
  temp files removed after each request; no path parameters from the client
  reach the filesystem.

## Verify

- Start the server on a spare port, `curl -F` or `python3 -c` a POST with
  `tests/svg/12_badge.svg` at width 300: PNG comes back and matches
  `microsvg tests/svg/12_badge.svg out.png --width 300` byte-for-byte; an
  invalid SVG returns the error JSON; a 9 MB payload is rejected.
- Open the page in a browser (the built-in browser pane via the preview
  tool is fine) and drop or pick a file; take one screenshot for the report.
- Commit (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report` with the endpoint contract and how to run it.
