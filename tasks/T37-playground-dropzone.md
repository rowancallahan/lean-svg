# T37 — Playground: drop an SVG, render with lean-svg, resize, compare  [Sonnet]

Python/JS only. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T37`
(branch `t37-dropzone`). Files: `playground/server.py`, a new
`playground/drop.html` (linked from `playground/index.html` with one line).
No Lean changes.

## Deliverable

`playground/drop.html`, served by the existing playground server:

- A drop zone (and a file picker, and a paste box for SVG text). Dropping an
  `.svg` renders it through `.lake/build/bin/lean-svg` via a new `POST
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
  `lean-svg tests/svg/12_badge.svg out.png --width 300` byte-for-byte; an
  invalid SVG returns the error JSON; a 9 MB payload is rejected.
- Open the page in a browser (the built-in browser pane via the preview
  tool is fine) and drop or pick a file; take one screenshot for the report.
- Commit (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report` with the endpoint contract and how to run it.

## Report

Branch `t37-dropzone`, merged with `main` first (no conflicts). No Lean changes.

Files:

- `playground/server.py` — new `POST /api/render` endpoint, `GET /drop.html`,
  `_run_api` (stderr + exit code), `_compare_pngs` (reuses
  `tests/run_tests.py::compare` when importable), `_parse_multipart` (so plain
  `curl -F` works). 413 now closes the connection so the undrained body is not
  parsed as a second keep-alive request.
- `playground/drop.html` — new page: drop zone, file picker, paste box, width
  slider 64–2000 (re-renders on `change`, i.e. on release), "Fit to pane"
  (sets the width to the lean-svg stage's content width; the pane is
  horizontally resizable), "Compare with resvg" toggle (ours | resvg | diff ×8
  with exact / within-8), render time + exit code metrics, verbatim error box,
  gallery strip of the last 12 files (object URLs, revoked on eviction).
- `playground/index.html` — one-line link to `/drop.html` in the header.

Endpoint contract (`POST /api/render`):

- Body: JSON `{svg, width?, background?, compare?}` or `multipart/form-data`
  with the same field names (`file` accepted as an alias of `svg`).
- `compare` unset/false: `200 image/png` (raw bytes of `lean-svg in.svg out.png
  --width W [--background C]`), headers `X-Render-Ms`, `X-Exit-Code`. Renderer
  failure: `422 {error, stderr, exit_code}`. Bad input: `400 {error}`;
  body > 8 MB + 64 KB or `svg` > 8 MB: `413 {error}`.
- `compare` true: `200 {ours, resvg, diff, metrics}`; `ours`/`resvg` are
  `{png (base64|null), error, stderr, exit_code, ms}`; `diff` (base64 PNG, ×8
  gain) and `metrics` (`{exact, within8, same_size}`) only when both PNGs
  decoded. resvg gets `-w W`, `--background C`, and `--skip-system-fonts
  --use-fonts-dir tests/corpora/resvg-test-suite/fonts` when that dir exists.
- Limits: width 1–4096, 20 s per renderer, temp dir `lean-svg-drop-*` removed in
  `finally`; the only filesystem paths are fixed names inside that temp dir.

Run: `lake build && python3 playground/server.py --port 8765`, open
`http://127.0.0.1:8765/drop.html`. Pillow + numpy are needed for `diff`/`metrics`;
`resvg` on PATH for compare.

Verified (server on port 8799, Lean v4.34.0 toolchain, resvg 0.48.1):

- `curl -F svg=@tests/svg/12_badge.svg -F width=300` and the JSON form both
  return 200 `image/png`, 360393 bytes, `cmp` byte-identical to
  `lean-svg tests/svg/12_badge.svg out.png --width 300`. `X-Exit-Code: 0`.
- `{"svg":"<svg …><rect"}` → 422 `{"error": "lean-svg: error: unterminated start
  tag <rect>", "stderr": …, "exit_code": 1}`; `svg=hello world` → 422 "no
  elements found".
- 9 MB multipart payload → 413 `request body too large (limit 8 MB)`; width 5000
  → 400.
- `compare=1` on 12_badge at 300 px: ours 360393 B / resvg 19412 B / diff
  6177 B, metrics exact 93.91 %, within-8 98.61 %, same_size true. No
  `lean-svg-drop-*` dirs left in `/tmp`.
- Headless Chromium (Playwright): picked 12_badge.svg via the file input →
  300×300, exit 0; compare toggle → three tiles + exact/within-8; pasted broken
  SVG → error box shows both renderers' exact stderr with exit codes; gallery
  holds both entries and clicking back re-renders; width 600 → 600×600; "Fit
  to pane" → 271 px at a 1400 px viewport. No page errors besides the
  favicon 404. Screenshot taken but not committed (no images tracked in repo).

Not done: the spec's `/Users/…/.worktrees/T37` path does not exist in the cloud
container; work was done on the same branch in `/home/user/lean-svg`. The
toolchain was installed from the GitHub release tarball because
`elan.lean-lang.org` and `api.github.com` are blocked by the proxy.
