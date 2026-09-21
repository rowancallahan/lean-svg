# T40 — Public GitHub Pages site: features, comparisons, demos, draw  [Opus]

A site at `https://rowancallahan.github.io/lean-svg/` that shows what this
renderer supports, how close it is to the references, and lets a visitor
play. Built and published by GitHub Actions on every push to `main`.
**Nothing generated is committed to the repository**: the workflow renders
everything fresh and uploads it as the Pages artifact, so the repo stays
small.

Source lives in `site/` (templates, CSS, JS, the generator) plus
`.github/workflows/pages.yml`. Add a link near the top of `README.md`.

## Comparison columns — ours, resvg, browser

Three renderings of the same file, side by side, in this order:

1. **lean-svg** — `.lake/build/bin/lean-svg` (this project).
2. **resvg 0.48.1** — the oracle, `resvg --skip-system-fonts --use-fonts-dir <suite>/fonts`.
3. **the browser** — the original `.svg` in an `<img>`, rendered live by
   whatever browser the visitor is using. Label it as such: it is the
   visitor's engine (Blink/WebKit/Gecko), not a fixed reference, so it is a
   sanity check, not a score.

**Do not include the usvg route anywhere on the site.** It is an internal
diagnostic; it would confuse a visitor about what this renderer does itself.

Score each file the way `tests/run_tests.py` does (percentage of pixels
within 8 levels of resvg, and exact), ours against resvg only. Never score
against the browser.

## Pages

1. **Home / features.** The C01–C55 audit table from `PLAN.md` ("Feature
   selection and corpus audit"), one row per feature, with: status
   (supported / partial / not yet / out of scope), the live pass rate for
   its corpus directories from the run, and a link into the gallery filtered
   to those directories. Group by the audit's four sections. Above it: a
   short honest summary of what the project is (safety first: one input
   file, one output file, total functions, no floats, proven effect
   boundary) and the headline number (direct-route pass rate on the resvg
   suite). Derive statuses from the measured pass rates plus an explicit
   override map in the generator for rows the corpus cannot measure; do not
   hand-write 55 statuses that will go stale.
2. **Gallery.** Every resvg-suite file, filterable by directory, status and
   a path search, sorted worst-first or by path, each card showing the three
   columns above plus a diff image against resvg, the two percentages, and
   our exit code and error text when we reject a file. This is the existing
   `tests/gen_gallery.py` page with the usvg route dropped, the browser
   column added, and styling that matches the rest of the site — reuse it,
   do not rewrite from scratch.
3. **Demos.** The project's own `tests/svg/*.svg` (the badge, spiral,
   Koch snowflake, Sierpinski, gradients, text, layers, dashes, arcs and the
   rest) in the same three columns, larger, with a one-line description of
   what each exercises. This is the "fun images" page.
4. **Draw.** A canvas where a visitor draws paths and shapes, producing SVG
   source shown live next to the browser's own rendering of it.
   **Be straight about the limitation:** a static site cannot run the Lean
   binary, so this page cannot render with lean-svg. Say so in one sentence
   and give the copy-pasteable local alternative (`git clone`, `lake build`,
   `python3 playground/server.py`, open `/drop.html`), which does compare
   all three. Do not fake a lean-svg result. If you find a genuinely
   working way to run the renderer in the browser, do not attempt it in this
   task — write it up at the end as a proposal.

Every page: a shared header with the four links, the repo link, the licence,
and the generation date and commit. Mobile-readable. No external JS or CSS
frameworks, no analytics, no fonts fetched from a CDN.

## Size and licensing

- Keep the whole artifact **under 400 MB** and say the measured size in the
  report. Thumbnails at 150 px, PNGs quantised or optimised if that is what
  it takes; full-size images only in the click-through overlay, generated
  only for files whose card is not passing.
- The suite's SVGs are republished (the browser column needs the original
  file). They are MPL-2.0: copy the suite's licence into the artifact,
  credit it visibly in the footer and on the gallery page, and state that
  the files are unmodified. Our own `tests/svg` files and the embedded fonts
  are ours and OFL respectively — the existing `NOTICE` covers the rest;
  link it in the footer.

## Workflow

`.github/workflows/pages.yml`, on push to `main` and on `workflow_dispatch`:
install elan and the pinned toolchain, `lake build`, install resvg 0.48.1,
clone the resvg test suite shallowly, run the generator, upload with
`actions/upload-pages-artifact` and deploy with `actions/deploy-pages`
(permissions `pages: write`, `id-token: write`, concurrency group `pages`).
Cache what is safe to cache (elan, the Lake build, the cargo install) and
report the cold and warm run times. The whole run should finish in under
20 minutes cold.

## Verify

- The generator runs locally end to end: `python3 site/gen_site.py --out
  site/_build` (add the flags it needs), and `python3 -m http.server` from
  that directory serves all four pages. Check each page loads, the filters
  and the overlay work, the three columns show three different images, and
  no request 404s (check the browser console and the server log).
- Card and status counts equal the CSV's, as `gen_gallery.py` already
  verifies.
- Artifact size measured and under the cap; report the breakdown.
- The workflow file is valid (`actionlint` if available, else a careful
  read) and does not run on pull requests from forks.
- README links the site near the top.
- Commit with author Rowan Callahan <rowan.l.callahan@gmail.com> and a
  message ending `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`,
  push, open a pull request against main whose description is the report and
  ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
  Do not merge it. Note in the PR that Pages must be enabled once by hand
  (repo Settings → Pages → Source: GitHub Actions) before the first deploy.

## Report

### What changed

| file | what |
|---|---|
| `site/gen_site.py` | the generator: runs the harness once, builds the images, derives the feature statuses, writes the five pages |
| `site/templates/shell.html` | shared header/footer (nav, licence essentials, generation date and commit) |
| `site/assets/site.css` | the whole stylesheet; no framework, no webfont, no CDN |
| `site/assets/gallery.js` | gallery filters, worst-first sort, deep links, click-through overlay |
| `site/assets/draw.js` | the drawing toy |
| `.github/workflows/pages.yml` | build and deploy on push to `main` and on `workflow_dispatch` |
| `README.md` | site link near the top; resvg/usvg/test-suite licence corrected |
| `NOTICE` | same licence correction, plus the oracle's fonts, the Actions and the site's republishing |
| `.gitignore` | `site/_build/` — nothing generated is committed |

### Numbers — one run, one width

`tests/run_corpora.py --corpus resvg --route direct --width 200`, oracle
`resvg 0.48.1` with `--skip-system-fonts --use-fonts-dir <suite>/fonts`,
pass = at least 99% of pixels within 8 levels. Every number on the site comes
from this single run; the demos page renders at 480 px and says so, and its
numbers are never mixed with these.

| directory | files | pass | pass rate |
|---|---|---|---|
| filters | 398 | 85 | 21.4% |
| masking | 93 | 53 | 57.0% |
| paint-servers | 151 | 124 | 82.1% |
| painting | 306 | 198 | 64.7% |
| shapes | 133 | 119 | 89.5% |
| structure | 262 | 115 | 43.9% |
| text | 379 | 178 | 47.0% |
| **total** | **1722** | **872** | **50.6%** |

Statuses on the CSV: pass 872, fail 843, unsupported 4, ref_failed 3. The
generator asserts the card count and the per-status counts equal the CSV's.
The suite has grown since the numbers quoted in the task (1722 files, not
1679). Where a directory did not change the counts reproduce exactly —
shapes 119/133 and masking 53/93, both as quoted; the rest gained files
(text 178/379 against 177/356, structure 115/262 against 115/247, filters
85/398 against 84/397, paint-servers 124/151 against 122/149, painting
198/306 against 198/304).

Derived feature statuses across C01–C55: supported 20, partial 9, not yet 20,
out of scope 6. Thresholds (stated on the page): supported ≥ 75%, partial
≥ 30%. Six rows carry an explicit override because the corpus cannot measure
them (C07, C08 have no fixture; C16, C34, C49–C52 are scope decisions; C54,
C55 are measured by the project's own harnesses).

### Artifact size

Apparent bytes, `_work/` (the harness run and the raw renders) excluded — the
workflow deletes it before uploading:

| part | size |
|---|---|
| thumbnails, 150 px, 64-colour palette (5 166 files) | 4.1 MB |
| click-through images, 200 px, 128-colour palette, non-passing cards only | 3.1 MB |
| demo images, 480 px | 607.7 KB |
| republished suite SVGs (1 722 files) | 1023.0 KB |
| demo SVGs | 445.7 KB |
| pages, data.json, CSS/JS, licence texts | 461.7 KB |
| **total** | **9.6 MB** |

As a tar, the shape `upload-pages-artifact` uploads: **16.45 MB**. The cap is
400 MB.

### Timings

Local, 4 vCPU: clean `lake build` 23.1 s; harness 11.0 s (1 722 files × two
renderers); images 12.3 s; demos 1.2 s; generator total **25.4 s**.
`cargo install resvg --version 0.48.1` compiled in 35.6 s here.

CI cold and warm times are **not measured**: the workflow only triggers on
push to `main` and on `workflow_dispatch`, neither of which a pull-request
branch can run, so the first real numbers will appear in the run summary
after this merges. From the local measurements the cold run is dominated by
the elan toolchain download, the cargo build of resvg and `lake build`, and
should land around 6–9 minutes on a 2-vCPU runner; a warm run (elan, `.lake`
and the resvg binary all cached) is the generator plus the suite clone, a
couple of minutes. The workflow writes both to `$GITHUB_STEP_SUMMARY`.

### Verify

- `python3 site/gen_site.py --out site/_build` runs end to end from a clean
  tree (25.4 s) and again with `--reuse` (13 s).
- `python3 -m http.server` from `site/_build`, then Chromium over all five
  pages: **0 console errors, 0 failed requests, 0 404s in the server log**
  (the one favicon 404 is gone — the icon is an inline data URI).
- Filters: dir → 120 shown of the batch, status, path search (38 files for
  `textPath`), reset, and the “show more” batching all work. Deep links from
  the feature page match the feature page's own counts exactly: C10
  `structure/svg,!structure/svg/nested` → 31, C14 → 20, C24 → 19.
- The overlay opens, shows four distinct decoded images (lean-svg, resvg,
  your browser, diff) and says “not rendered” where a file produced no image.
- Three different images per card confirmed programmatically (distinct URLs,
  all with non-zero `naturalWidth`).
- Card and status counts equal the CSV's (asserted in the generator).
- Mobile (390 × 844): no horizontal page scroll on any of the five pages.
- `actionlint 1.7.7` on `.github/workflows/pages.yml`: clean. No
  `pull_request` trigger, so a fork's PR can never run it.
- `python3 tests/run_tests.py` after the rebuild: 23/27, unchanged.

### Deviations from this file, and why

A scope update from Rowan reached this session (relayed by the session doing
the rename) and overrides three points above:

1. **Draw page**: no lean-svg comparison, no “a static site cannot run the
   binary” paragraph, no local-alternative instructions. It is a browser-only
   drawing toy that shows the SVG source it produces.
2. **Licensing is now the highest-priority part.** A fifth page,
   `licensing.html`, lists every third-party component, its licence and how it
   is used, with the essentials repeated in every page footer.
3. **The suite is republished** (as this file already said), which is what the
   browser column needs.

The renderer binary is resolved from `lakefile.toml`, falling back to
`lean-svg` then `microsvg` in `.lake/build/bin`, with `--bin` overriding: the
rename landed mid-task and the generator survived it unchanged.

### Licensing audit — what `NOTICE` and `README.md` got wrong

Re-derived from the code and the harnesses rather than from `NOTICE`:

- **resvg and usvg are not MPL-2.0.** They are `Apache-2.0 OR MIT`, relicensed
  in 0.45.0 (`CHANGELOG.md`, resvg#838); the version used and read here is
  0.48.1, whose `Cargo.toml` says `license = "Apache-2.0 OR MIT"` and whose
  repository ships `LICENSE-APACHE` and `LICENSE-MIT`. `NOTICE`, the README's
  licensing section and this task file all said MPL-2.0. Fixed in both files;
  the site says `Apache-2.0 OR MIT` and ships both texts.
- **The test suite carries resvg's licence**, not a separate MPL-2.0 one: the
  files live in `crates/resvg/tests/tests` in that repository.
- **The oracle's fonts were not credited anywhere.** The reference renders are
  produced with the suite's bundled faces pinned (`--use-fonts-dir`): Amiri,
  M PLUS 1p, Noto Sans/Serif/Mono/Devanagari/Malayalam/Znamenny, Roboto Flex,
  Sedgwick Ave Display, Source Sans Pro (SIL OFL 1.1); CFF-and-SBIX, Noto
  Color Emoji CBDT, Yellowtail (Apache-2.0); Twitter Color Emoji (MIT). Added
  to `NOTICE` and to the licensing page. No font file is redistributed.
- **The Actions used by the site build** (checkout, cache,
  upload-pages-artifact, deploy-pages; all MIT) were not credited. Added.
- `simplecss`, `svgtypes` (`Apache-2.0 OR MIT`), tiny-skia and Skia
  (BSD-3-Clause), Noto Sans (OFL 1.1), Lean 4 and Lake (Apache-2.0), NumPy
  (BSD-3-Clause), Pillow (MIT-CMU), fontTools (MIT) and lean-zip (Apache-2.0)
  were checked against the upstream manifests and are correct as stated.

### Not done

- CI cold/warm times, as above.
- GitHub Pages must be enabled once by hand (Settings → Pages → Source:
  GitHub Actions) before the first deploy can succeed.

### Proposal: running the renderer in the browser (not attempted)

The Draw page cannot invoke lean-svg, and the gallery's “ours” column is a
pre-rendered PNG. Both would change if the renderer ran in the visitor's
browser. The shape of it:

1. Lean 4 compiles through C, and the Lean runtime has an Emscripten target
   (`lean4` is built for WASM in the web editor). `Main.lean` is the wrong
   entry point — it opens files — but `LeanSvg.Render` is not: the effect
   boundary means the renderer proper is bytes-in, bytes-out.
2. Export one `@[export]` function `renderBytes : ByteArray → UInt32 →
   Option ByteArray` and link it with `emcc` against the WASM Lean runtime,
   with no filesystem and no environment in the module.
3. The page would then do what `playground/server.py` does now, locally: SVG
   text in, PNG out, scored against nothing (resvg is not available in the
   browser, so the “vs resvg” column stays pre-rendered).
4. The cost to check first: the WASM bundle size (the embedded font modules
   alone are megabytes of Lean data), the startup time of the Lean runtime,
   and whether the fixed-point arithmetic hits any `Int`/`Nat` boxing path
   that is slower under WASM than native.

That is a task of its own, and it would make the Draw page a genuine
three-column comparison rather than a toy.
