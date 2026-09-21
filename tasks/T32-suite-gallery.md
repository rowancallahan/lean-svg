# T32 — Browsable gallery of the resvg test suite  [Sonnet]

Python/HTML only. Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T32`
(branch `t32-gallery`). Files: new `tests/gen_gallery.py`; `tests/run_corpora.py`
only to add a `--keep-renders DIR` flag that saves each file's reference and
our render (PNG) under `DIR/<corpus>/<route>/<relative path>.{ref,ours}.png`
(no other behaviour change; default off). No Lean changes.

## Deliverable

`python3 tests/gen_gallery.py --out tests/out/gallery [--width 150] [--route direct|usvg|both]`:

1. Runs `run_corpora.py --fast --no-worst --corpus resvg --route <r>
   --keep-renders <out>/renders --out <out>/run` (or reuses an existing run
   with `--reuse`), then writes a diff PNG per file (per-pixel max channel
   diff, amplified ×8, transparent → shown on white) next to the renders.
2. Writes `<out>/index.html`, a static page (no server logic; served by the
   `reports` config in `.claude/launch.json`, i.e. `python3 -m http.server
   8767` from the repo root) with:
   - filters: top-level directory (structure, painting, shapes, masking,
     paint-servers, text, filters), subdirectory, status (pass / fail /
     error / unsupported / size-mismatch), route toggle if both were run,
     and a text search on the path;
   - sort by within-8 ascending (worst first) or by path;
   - one card per file: path, status badge, within-8 and exact %, max diff,
     our exit code and stderr excerpt if any, three thumbnails (reference,
     ours, diff) that open a large side-by-side view on click (a simple
     overlay in the same page), and a link to the SVG source;
   - a header with the per-directory pass table (from the CSV);
   - loads its data from a `data.json` the script writes, so the page
     stays small; thumbnails are lazy-loaded.
3. Runtime target under 3 minutes for both routes at 150 px on this machine.

## Verify

- Run it for both routes; confirm the card count equals the CSV row count
  and the status counts equal the CSV's; open the page with
  `python3 -m http.server` and check in a headless way that `data.json`
  loads (e.g. `curl` it) and that at least one failing card's three PNGs
  exist. Report total runtime and the on-disk size of `tests/out/gallery`.
- `tests/out/` is gitignored: commit only the script and the harness flag.
- `python3 tests/run_corpora.py --fast --limit 20` still works with the
  flag off (byte-identical CSV columns).
- Commit on the branch (`-c user.name="Rowan Callahan" -c user.email="rowan.l.callahan@gmail.com"`,
  message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
  Append `## Report`.

## Report

This worktree branched from main before the `tasks/T32-suite-gallery.md` /
`T34` / `T36` files existed (it was at `4172f64`, main has since moved to
`ef62a4b`); this file itself did not exist here and was added verbatim from
main before appending this section, so the commit is self-contained.

**Files changed**

- `tests/run_corpora.py`: added `--keep-renders DIR` (default `None`, no
  behaviour change when omitted). `render_one()` gained a `keep_renders_dir`
  parameter and a `save_renders()` helper called from `cleanup()`; whatever
  of `<slot>_ref.png` / `<slot>_ours.png` exist at the point a file's row is
  finished (however far rendering got — `ref_failed` rows save nothing,
  `unsupported`/`timeout` save only the ref, etc.) are copied to
  `DIR/<corpus>/<route>/<relative path>.{ref,ours}.png`. Threaded through
  `run_corpus_route()` and `main()`.
- `tests/gen_gallery.py` (new): drives `run_corpora.py --fast --no-worst
  --corpus resvg --keep-renders --out <out>/run`, then for every row with
  both a `.ref.png` and `.ours.png` writes a `.diff.png` next to them
  (both images composited over white via `run_tests.over_white`, per-pixel
  max-channel abs diff, ×8 gain, white-tinted-red — this is a *separate*,
  purely visual diff from the pass/fail metric, which stays exactly as
  `run_tests.compare()` computes it on raw RGBA). Writes `<out>/data.json`
  (one record per CSV row — corpus/route/file/dir/top/status/status-group/
  exact/within/max_d/size/ours_rc/ours_err and relative image + SVG-source
  paths, URL-quoted for the handful of `#RRGGBB`-named fixtures) and
  `<out>/index.html`, a static page with the top/subdir/status/route/search
  filters, worst-first-or-path sort, a per-route per-directory pass table
  computed from the CSV, lazy-loaded (`loading="lazy"`) thumbnails, and a
  click-to-overlay side-by-side view. `--width` (default 150) only sets the
  thumbnail CSS box size — the harness always renders at its own `--fast`
  resvg width (100 px); it does not exist as a `run_corpora.py` flag and none
  was added, per the task's "no other behaviour change" constraint.
- `tasks/T32-suite-gallery.md`: added (see note above) and this `## Report`.

**Verify — done**

- Ran both routes on the full, unsampled resvg-test-suite (1679 files/route,
  no `--limit`): `python3 tests/gen_gallery.py --out tests/out/gallery
  --route both --bin /Users/rowancallahan/pdf_renderer/.lake/build/bin/microsvg`.
  Card count in `data.json` is 3358, exactly `1679 + 1679` CSV rows
  (`resvg_direct.csv` + `resvg_usvg.csv`). Status counts match exactly:
  CSV `{pass: 1384, fail: 1964, unsupported: 4, ref_failed: 6}` ==
  `data.json` `{pass: 1384, fail: 1964, unsupported: 4, ref_failed: 6}`.
- Served with `python3 -m http.server 8767 --bind 127.0.0.1` from the
  worktree root and checked headlessly with `curl`: `index.html` → 200,
  `data.json` → 200 (valid JSON, confirmed by parsing), a `.ref.png` for a
  `fail`-status card → 200, and the URL-encoded source link for a
  `#RGB-color.svg`-style fixture → 200. Also opened the page in the
  built-in browser pane and interactively verified the directory tables,
  the status/search filters (counts update correctly, e.g. `status=pass`
  + `q=gradient` → 31/3358), and the click-to-overlay side-by-side view.
- `tests/corpora` is a symlink (not a directory) to the main tree's
  `tests/corpora`, so `git status` still shows it as untracked despite the
  `tests/corpora/` gitignore rule (that rule only matches directories); it
  is deliberately left out of the commit, along with `tests/out/`.
- `python3 tests/run_corpora.py --fast --limit 20` (flag off): CSV header
  and every non-timing column are identical to a same-flags run from the
  unmodified main tree (`ms_ours`/`ms_ref` differ, as they always do
  run-to-run); confirms no behaviour change when `--keep-renders` is
  omitted.
- Commit made on `t32-gallery` with the required `-c user.name`/`-c
  user.email` and trailer; only `tests/run_corpora.py`, `tests/gen_gallery.py`
  and this task file are staged (`tests/out/` and the `tests/corpora`
  symlink are not).

**Numbers**

- Runtime, full resvg-test-suite, both routes, from scratch (harness +
  keep-renders + diff generation + `data.json`/`index.html`): **~19–20 s**
  (harness ~18 s for 2×1679 files at `--fast` width 100 px, jobs=8; diff
  generation for the 3348 file pairs that had both images ~1.3 s). With
  `--reuse` (CSVs/renders already on disk, only diffs/HTML redone): ~0.3 s.
  Both are far under the 3-minute budget.
- On-disk size of `tests/out/gallery`: **159 MB** total — `renders/` 157 MB
  (10048 PNGs: ref/ours/diff at 100 px for up to 1679 files × 2 routes),
  `run/` 564 KB (the two CSVs + `summary.md`), `data.json` 1.8 MB,
  `index.html` 12 KB.

**Regenerate in the main tree**

```
python3 tests/gen_gallery.py --out tests/out/gallery
```

(defaults: `--route both`, `--width 150`, `--bin
.lake/build/bin/microsvg`; `tests/corpora` already exists as a real
directory in the main tree, no symlink needed there). Serve with
`python3 -m http.server 8767` from the repo root (the `reports` entry in
`.claude/launch.json`) and open `http://localhost:8767/tests/out/gallery/`.

**Not done / deviations**

- None from the spec. One judgment call: `--width` controls the gallery's
  thumbnail *display* size only, not the harness render resolution, since
  `run_corpora.py` has no per-invocation width override and the task
  explicitly limits changes to that file to the `--keep-renders` flag.

