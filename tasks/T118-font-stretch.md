# T118 — Source Sans Pro, Noto Sans ExtraCondensed and font-stretch  (branch `claude/feat-font-stretch`)

Rowan approved (from T110's report, `tasks/T110-font-family-suite.md`):
1. Embed **Source Sans Pro Regular** (OFL 1.1, Adobe; Reserved Font Name
   "Source" — keep the family name exactly "Source Sans Pro" only if the OFL
   RFN rules allow it for an unmodified-name subset; if subsetting counts as
   modification under the RFN clause, read the licence carefully and report
   before embedding under another name) and **Noto Sans ExtraCondensed**
   (OFL 1.1), from the resvg suite's `fonts/` (licence files there) or
   upstream, via `tests/gen_font_module.py --no-glyph-names`, T94 layout.
   Licence text in `LeanSvg/Fonts/`, `NOTICE`, README "Licensing and
   credits" row, `LeanSvg/Fonts/README.md`. Keep the binary under 75 MB.
2. Parse **`font-stretch`** (keywords, percentages, `narrower`/`wider`,
   inherit) as usvg does, add a stretch column to `FontSet.styles`, and match
   stretch before style/weight as fontdb does (`FamilyMatch.pick` and the
   suite path).
3. Remove Source Sans Pro from `suiteOnlyFamilies` so it resolves.
Targets (resvg suite, now judged with T110's harness fonts):
`text/font-family/source-sans-pro.svg`, `text/font-family/font-list.svg`,
`text/font-stretch/{extra-condensed,inherit,narrower}.svg`.
Do not change how generic families resolve (Chromium-first, T106).

---

## Round 7 rules (read with the common rules below)

- **Short task, hard timebox: about 2 hours of work.** Fix what is clearly
  ours and bounded; for anything bigger, write down the cause, the fix you
  would make and its size in the report, push, and end. Do not start
  rewrites.
- **No speed work.** Do not optimise or restructure hot paths; Rowan will
  run the speed phase later. A fix must not slow the suite down noticeably
  (`scratchpad`-style timing: `run_corpora.py` wall time within ~5%).
- **Pass criteria** (`tests/criteria.csv`, `docs/DECISIONS.md`): a file's
  reference is resvg where resvg is correct, Chromium where resvg is wrong
  and Chromium is right, otherwise Rowan's verdict. Do not change
  `criteria.csv` or `realworld_verdicts.csv`; if you believe a file's
  reference is wrong, say so in the report with evidence.
- **Behaviour that must not change:** one input file read; at most the PNG
  and (with `--warnings`) `<out>.warnings.txt` written, no-clobber; nothing
  on stdout/stderr; exit codes as in `docs/DECISIONS.md`; no external
  resource ever loaded. `tests/run_adversarial.py` must stay all clean.
- **Real-world corpus vs Chromium:**
  `python3 tests/run_corpora.py --corpus realworld --ref chrome --out /tmp/rw --no-worst`
  (Chromium is preinstalled; `tests/render_chrome.py` renders references).
  When you look at our PNGs, composite them on white first: they are
  transparent, and an image viewer shows transparency as black.
- Fonts: only permissively licensed fonts (OFL, Apache, Bitstream Vera or
  equally permissive), verified upstream, licence text in `LeanSvg/Fonts/`,
  credits in `NOTICE` and README "Licensing and credits". Keep the binary
  under 75 MB (now ~46 MB).

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

- **`font-stretch`** (`Svg.parseFontStretch`, `Style.fontStretch`, width
  class 1–9): exactly usvg 0.48.1's `conv_font_stretch` — the nine keywords;
  `narrower` = `condensed` and `wider` = `expanded` (absolute, as usvg does,
  not relative to the parent); `inherit` keeps the parent's value (usvg's
  svgtree `resolve_inherit`); anything else, **percentages included**, is
  `normal` (usvg's `_ => Normal`; Chromium would map `62.5%` to
  extra-condensed, usvg does not). The CSS `font` shorthand resets stretch to
  normal and then takes a stretch keyword it names.
- **Matching**: `FontSet.styles` is now `(weight, italic, stretch)`;
  `FamilyMatch.matchStretch` is fontdb's `find_best_match` step 4a (exact,
  else for ≤ normal nearest narrower then nearest wider, above normal the
  reverse); `FamilyMatch.pick` filters by stretch before style and weight.
  `Text.baseFont` takes the span's stretch (`SpanProps.stretch`) and routes
  Noto Sans through `pick` only when stretch ≠ normal, so every normal-stretch
  path is unchanged. Generic families untouched.
- **Font**: Noto Sans ExtraCondensed 2.000 (the suite's
  `NotoSans-ExtraCondensed.ttf`; typographic family "Noto Sans", width class
  2, OFL 1.1, same Google copyright as the other Noto Sans faces, licence
  `LeanSvg/Fonts/LICENSE-OFL.txt`), appended last to `FontSet` (index 34) so
  every existing fallback order is unchanged. Module 356,958 bytes of Lean
  source, 266,481 bytes of font. Binary 47.1 MB (< 75 MB).
- `tests/svg/118_font_stretch.svg`: keywords, nearest-stretch, inherit,
  stretch over bold italic, expanded → normal, shorthand, percentage.

## Skipped, and why

- **Source Sans Pro not embedded; `suiteOnlyFamilies` unchanged (items 1a
  and 3).** Its licence (`fonts/SourceSansPro-LICENSE-OFL.md`): "Copyright
  2010-2018 Adobe … with Reserved Font Name 'Source'". OFL 1.1 defines a
  Modified Version as "any derivative made by adding to, deleting, or
  substituting … any of the components of the Original Version, by changing
  formats or by porting". Subsetting deletes glyphs/hinting and the Lean
  module changes the format (and reorders tables), so what we would embed is a
  Modified Version, and §3 says it "may [not] use the Reserved Font Name(s)
  unless explicit written permission is granted". "Source Sans Pro" contains
  the RFN, so embedding it under that name needs Adobe's permission. The task
  says to report before embedding under another name: **Rowan to decide**.
  Options: (a) embed under a non-RFN name (e.g. "Adobe Sans Subset") and keep
  an alias `"source sans pro"` → that module in `FamilyMatch.aliases` (the
  alias is a lookup key, not the font's primary name — whether that still
  counts as "using" the RFN is the question for Rowan); (b) Source Sans 3
  carries the same RFN, so it does not help; (c) leave as is. Size if
  embedded: ~290 KB Lean source (T110). Fix size once decided: ~20 lines +
  generated module, ~30 min.
- `LeanSvg/Fonts/README.md` table **Total** row not updated (time); add
  266,481 / 356,958 to it.
- `tests/check_shape.py`'s `NOTO_SANS` list not extended to the new face.
- Real-world corpus vs Chromium not run (time). No real-world file should
  move: only a non-normal `font-stretch` changes any path.

## Report

Baseline b570a42 (branch start), after `467ceaf` + docs.

- `lake build`: clean, no new warnings. `check-theorems.sh`: `invariants ok`,
  `theorems ok`. `run_adversarial.py`: 171/171 clean.
- resvg suite, fast (100 px): pass 1548 → **1551**; 3 fail → pass, **0 pass →
  fail**, no other file moved > 0.1 points.
- resvg suite, 200 px: pass 1572 → **1575**; 3 fail → pass, **0 pass → fail**.

| target | 200 px within-8 before | after |
|---|---|---|
| text/font-stretch/extra-condensed | 97.395 | 99.985 (pass) |
| text/font-stretch/inherit | 97.395 | 99.985 (pass) |
| text/font-stretch/narrower | 97.395 | 99.985 (pass) |
| text/font-family/source-sans-pro | fail | unchanged (not embedded, see above) |
| text/font-family/font-list | fail | unchanged (not embedded, see above) |

- Timing: fast pass 11.4 s → 11.7 s wall. The 200 px after-run (25.8 s vs
  18.4 s) ran concurrently with the theorem and adversarial checks, so it is
  not a valid comparison; re-time it alone. Nothing on a hot path changed
  (one extra `Nat` compare per span in `baseFont`).
- `run_tests.py`: every existing file's score identical to baseline (63/80
  pass before, 63/81 after). **The new `118_font_stretch.svg` fails: 97.19%
  within-8 vs resvg.** Not investigated (session ended). Likely suspects, in
  order: the `font: condensed 28px Noto Sans` shorthand line (our
  `fontShorthand` may not skip a leading stretch keyword before the size, or
  usvg's `FontShorthand` parse differs), then the `ultra-condensed` /
  `semi-condensed` lines. Next step: render each line alone against resvg
  (`resvg --skip-system-fonts --use-fonts-dir tests/corpora/resvg-test-suite/fonts`),
  fix ours or drop the line that is outside usvg's behaviour; ~30 min.
- **Not run:** `run_tiles.py`, real-world corpus vs Chromium. The integrator
  should run both.
