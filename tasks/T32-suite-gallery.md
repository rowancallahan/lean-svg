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
