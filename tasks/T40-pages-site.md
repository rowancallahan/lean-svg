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

1. **lean-svg** — `.lake/build/bin/microsvg` (this project).
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
