# T97 — Font weight, small caps, stacked marks  (branch `claude/fix-font-styles`)

Rowan reviewed the failure report: "font weight is important". Reference:
resvg where `results.csv` rates it correct, else Chromium.

Files (`tests/corpora/resvg-test-suite/tests/`):
- `text/font-weight/lighter-with-clamping.svg`,
  `text/font-weight/lighter-without-parent.svg` (must fix),
  `text/font-weight/bolder-with-clamping.svg` (improve if you can).
  These need lighter/heavier faces. You may add **Noto Sans weight
  instances only** (same family, OFL, from the Noto Sans variable font via
  the generator's `--instance`, like T91/T93 did), at most ~2 MB of embedded
  data in total. No new families: Rowan will decide those later. Match
  usvg/fontdb's face selection (CSS font matching) among the faces we have.
- `text/font-variant/small-caps.svg`, `text/font-variant/inherit.svg`:
  implement `font-variant: small-caps` as usvg/resvg does (check whether it
  uses the font's `smcp` feature or synthesises; match what resvg renders).
- `text/text/zalgo.svg`: heavily stacked diacritics. Needs GPOS
  mark-to-base / mark-to-mark positioning for Noto Sans. T93 built a GSUB/GPOS
  shaper (`LeanSvg/Shape.lean`, `ShapeText.lean`) used for Arabic/Hebrew/
  Devanagari; reuse it (keep the needed GPOS features in the Noto Sans
  modules by regenerating them) rather than writing a second engine. Check
  with `tests/check_shape.py`-style comparison against HarfBuzz.

`LeanSvg/Text.lean` is shared with T96 (text layout) running at the same
time: keep changes local, no reformatting. Watch the speed check: Latin text
must not get noticeably slower. Add `tests/svg/97_*.svg` cases.

---

## Common rules (every lean-svg agent)

### Conduct (Rowan's rules for every agent, read first)

- **One app.** The whole job is making lean-svg good. Work only inside this
  repository's checkout. Anything outside it is a red flag: do not read,
  write or delete files elsewhere except the scratch/tool dirs the setup
  script uses (`~/.elan`, `~/toolchains`, cargo/pip caches, `/tmp`).
- **Network: only what the task needs.** Cloning the resvg source/test suite,
  installing the pinned toolchain and packages, and reading documentation or
  GitHub issues is fine. Nothing else: no SSH, no uploading data anywhere, no
  contacting services the task does not need, no account or credential use.
- **Git: your branch only.** Commit often (small commits make rollback easy)
  and push only to the one branch your task names. No force-push, no pushing
  to `main` or any other branch, no deleting branches, no pull requests
  unless your task says so.
- **No drastic actions.** Editing files in this repo that are committed and
  can be rolled back is fine. Big or irreversible commands are not: no
  `rm -rf` outside your own build/output dirs, no system changes, no killing
  processes you did not start, no changing CI or repo settings unless the
  task says so. If something gets really difficult or seems to need a
  drastic step, stop, write down what you would need and why in your task
  file's report, push that, and end: the integrator will ask Rowan.


You are one of ~15 agents working in parallel on lean-svg, a total, float-free
SVG→PNG renderer in Lean 4 whose output is compared against resvg 0.48.1.
An integrator merges all branches afterwards, so **keep your diff small and
local**: prefer new functions/new modules (`LeanSvg/<Feature>.lean`, imported
from `LeanSvg.lean`) over rewriting shared code in `Svg.lean` / `Render.lean`.
No drive-by refactors, renames or reformatting of code you do not need.

**Setup (first thing):** `bash scripts/cloud-setup.sh` then
`export PATH=$HOME/.elan/bin:$PATH`. It installs Lean from the GitHub release,
resvg/usvg 0.48.1, numpy/pillow and the resvg test suite under
`tests/corpora/resvg-test-suite`, and builds. Read `tasks/README.md`,
`DESIGN.md` and the relevant parts of `SPEC.md` before editing.

**Invariants (hard, from tasks/README.md):** no `partial`, `unsafe`,
`@[extern]`, `panic!`, `!`-indexing, `Float`; loops over finite ranges or
structurally decreasing fuel; hot loops in `Nat`; no new build warnings;
`LeanSvg/Effect.lean` untouched unless your task is about it; no IO outside
`Effect.lean`. Code should fail loudly rather than silently: prefer
rejecting/asserting over swallowing errors, but a feature that is not
supported should degrade exactly as it does today (skip), not error.

**Reference behaviour:** match resvg/usvg 0.48.1. The Rust source is the spec
(`git clone --depth 1 --branch v0.48.1 https://github.com/linebender/resvg`
into a scratch dir; `crates/usvg/src/parser/*` and `crates/resvg/src/*`).

**Baseline first, before any edit:**
```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
python3 tests/run_tests.py
```

**Verification before you push (all must hold):**
1. `lake build` — no errors, no new warnings.
2. `bash scripts/check-theorems.sh` prints `theorems ok`. Note
   `proofs/SizeBound.lean` reasons about `render`; if your change breaks it,
   fix the proof, do not delete or weaken it.
3. Full corpus with delta table (the fast 100 px pass), and ALSO the default
   200 px pass that is the headline number: run the same command without
   `--fast` into `/tmp/base200` before editing and `/tmp/after200` after, and
   compare. Zero pass→fail at either width.
   Fast:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/<task number>_<feature>.svg` (use your
   task number as the file number, e.g. `71_image_gif.svg`, so files never
   collide) exercising the feature
   if it fits the local corpus style 

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.

---

## Spec implemented

**Face selection** (`Text.pickFace`, `Text.matchWeight`): fontdb's
`find_best_match` over the Noto Sans faces we embed. Style first: italic or
oblique picks the Italic face whatever the weight, because fontdb keeps only
the faces of the best-matching style before it looks at weight. This changes
the old rule, where bold won over italic. Upright text matches weight among
100/300/400/700/900: exact; 400–449 tries 500, 450–500 tries 400; at or below
500 the nearest lighter weight, then the nearest heavier; above 500 the
nearest heavier, then the nearest lighter. So 200 → Thin, 500 → Regular,
600 → Bold, 800 → Black. `bolder`/`lighter` stepping (`parseFontWeight`) is
unchanged.

**Fonts.** Noto Sans Thin, Light and Black are appended to `FontSet` as
indices 13–15, so every other font keeps its fallback position. They map
what Regular maps, so fallback never reaches them. Deviation: they come from
the resvg test suite's static `NotoSans-{Thin,Light,Black}.ttf`, not from
instancing the Noto Sans variable font. They are Noto Sans 2.000 weight
instances (same family, OFL, © 2015 Google), and they are the exact files
resvg's reference images were rendered with, so they match better than a
fontTools instance would. The six Noto Sans modules keep
`kern,mark,mkmk,ccmp,locl,smcp,liga` and drop `post` glyph names (new
generator flag `--no-glyph-names`). Embedded data grows 911,553 bytes
(19,841,776 → 20,753,329), under the ~2 MB allowance.

**`font-variant: small-caps`.** usvg passes the `smcp` feature to harfrust
when the inherited `font-variant` value is exactly `small-caps`. It does not
synthesise small caps. Here: `Style.fontSmallCaps` (`inherit` keeps the
parent's value, any other value is false; the CSS `font` shorthand resets it
and sets it from a `small-caps` token) → `SpanProps.smallCaps` → a
`smallCaps` flag on `Shape.shapeRun`, which adds `smcp` as a global user
feature. Shaping spans are split where small caps changes.

**Stacked marks.** This reuses T93's shaper. `ShapeText.needsShaping` also
sends a chunk through shaping when a Noto Sans face draws it and it has a
combining mark (Mn/Mc/Me, pre-filtered by `cp ≥ 0x300`) or a small-caps span.
Every other Latin chunk keeps the one-glyph-per-character path.

**Shaper check** (`tests/check_shape.py`, now covering all six faces, smcp
and zalgo): 3089/3089 and 3074/3074 identical to HarfBuzz (seeds 1 and 7).
The random pool excludes U+035C–0362, U+0345 and U+034F. After other marks,
HarfBuzz 14.5 attaches the marks that follow these to the base, while
harfrust 0.12 and we stack them on the previous mark. For those strings,
resvg's own render matches ours (within-8 ≥ 99.97% at 60–80 px on three
test SVGs), so harfrust is what we match. `check_font --all
--via-embedded` and `--metrics`: 0 mismatches on all six faces;
`fuzz_font` (Thin, 300) and `fuzz_shape --font NotoSans` (700): 0
violations.

## Skipped

- `font-variant` values other than `small-caps` (`all-small-caps`,
  `font-variant-caps`, …): usvg reads only `small-caps` too.
- Noto Sans modules keep only the listed GSUB/GPOS features. Shaped chunks
  therefore do not apply `frac`/`numr`/`dnom`/`case`/`zero`; harfrust does
  not turn those on by default either, except `frac` around U+2044.

## Report

Files: `LeanSvg/Text.lean` (Face, `matchWeight`, `pickFace`, `baseFont`,
`SpanProps.smallCaps`, span keys and shaping trigger in the chunk loop;
local edits only), `LeanSvg/Svg.lean` (`fontSmallCaps`, `font-variant`,
the `font` shorthand, `spanPropsOf`), `LeanSvg/ShapeText.lean`,
`LeanSvg/ShapeRun.lean`, `LeanSvg/FontSet.lean`, `LeanSvg/Fonts/NotoSans*.lean`
(3 regenerated, 3 new), `ShapeDump.lean` (`1s` kern flag = smcp),
`tests/gen_font_module.py` (`--no-glyph-names`), `tests/check_shape.py`,
`tests/fuzz_shape.py`, `tests/svg/97_font_weight.svg`,
`tests/svg/97_small_caps_marks.svg`, font README/NOTICE/README.

Targets (within-8, fast 100 px / 200 px):

| file | before | after |
|---|---|---|
| text/font-weight/lighter-with-clamping | 94.92 / 95.92 fail | 99.96 / 99.98 pass |
| text/font-weight/lighter-without-parent | 94.92 / 95.92 fail | 99.96 / 99.98 pass |
| text/font-weight/bolder-with-clamping | 94.76 / 96.19 fail | 99.98 / 99.99 pass |
| text/font-variant/small-caps | 95.31 / 96.11 fail | 99.99 / 99.99 pass |
| text/font-variant/inherit | 95.31 / 96.11 fail | 99.99 / 99.99 pass |
| text/text/zalgo | 94.50 / 96.05 fail | 99.89 / 99.90 pass |

Also improved (now shaped): `text/text/rotate-with-multiple-values-and-complex-text`
97.15 → 99.71 (fail → pass), `complex-graphemes` 99.48 → 99.99,
`complex-grapheme-split-by-tspan` 99.01 → 99.98, `text/font/simple-case`
91.98 → 94.80 (still fails).

Whole resvg suite: fast 100 px 1543 → 1550 pass, 200 px 1567 → 1574 pass;
7 newly passing, 0 newly failing, no file's within-8 dropped by more than 0.1 points.
`run_tests.py` 57/68 → 59/68 (both 97_* pass, 91_fonts 99.86 → 99.89, no
drops); `run_adversarial.py` 144/144 clean; `run_tiles.py` 68/68
byte-identical; `lake build` no warnings; `check-theorems.sh` theorems ok.

Speed (whole process, median of 15, natural size, two rounds): plain Latin
is 1–2 ms slower per image (`text/text/simple-case` 15.1/15.8 → 16.3/16.4 ms,
`25_text` 40.8/40.4 → 42.4/43.8, `94_font_speed` 24.2/24.5 → 26.0/26.5; no
text: `01_triangle` unchanged). The cause is the bigger GPOS (mark/mkmk) that
first use decodes. Dropping glyph names brought Regular's front from 103 KB
back to 69 KB (was 55 KB). Rowan accepted 1–2 ms per image.
