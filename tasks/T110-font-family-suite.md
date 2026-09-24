# T110 — resvg-suite text/font-family and font-stretch failures after T106  (branch `claude/fix-suite-font-family`)

After T106 (Chromium-style family matching, new bundled fonts) these
resvg-correct files still fail (within-8 at 200 px, ~97.3–98.4%):

text/font-family/{bold-sans-serif,cursive,fallback-1,fantasy,font-list,monospace,sans-serif,serif,source-sans-pro}.svg
text/font-stretch/{extra-condensed,inherit,narrower}.svg

resvg renders the suite with `--skip-system-fonts --use-fonts-dir
tests/corpora/resvg-test-suite/fonts`, so its generic families map to the
suite's own fonts (see `run_corpora.py` and usvg's fontdb defaults). T106
kept suite fonts (FontSet index < 16) on usvg's rules. Find out, file by
file, which font resvg picks and which we pick, and why the pixels differ
(wrong face, missing face we do not embed, kerning, stretch). Fix what is
ours without undoing T106's Chromium matching for real-world files: the
resvg suite must follow resvg, real-world files Chromium. If a file can only
pass by embedding another suite font, report the font, licence and size
instead of adding it.

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

**Finding: the local resvg oracle, not our renderer, was wrong for the
generic-family files.** The task's premise ("its generic families map to the
suite's own fonts") did not hold. `run_corpora.py` ran
`resvg --skip-system-fonts --use-fonts-dir <suite fonts>` with the CLI's
generic defaults (`crates/resvg/src/main.rs:614-618`: Times New Roman, Arial,
Comic Sans MS, Impact, Courier New). None is in the suite's font dir, so
resvg printed `No match for 'serif' font-family` and **drew no text** for
`serif`, `sans-serif`, `cursive`, `fantasy`, `monospace` and for
`fallback-1.svg` (usvg appends `serif` to every list,
`crates/usvg/src/text/mod.rs:114`). The `resvg=1` verdicts come from resvg's
integration harness (`crates/resvg/tests/integration/main.rs:28-32`), which
maps serif → Noto Serif, sans-serif → Noto Sans, cursive → Yellowtail,
fantasy → Sedgwick Ave Display, monospace → Noto Mono.

**Change** (harness only, no Lean code): `run_tests.resvg_font_args` gets
`suite_generics`; `run_corpora.py` passes it, so the oracle adds those five
`--<generic>-family` flags. `tests/resvg_as_bin.py` passes the same flags.
`run_tests.py` (local tests) keeps the CLI defaults: with the flags,
`106_font_families` and `41_text_decoration` dropped 4.5 and 0.8 points
because their generic-family text targets Chromium (T106), not resvg.

This also fixes 5 other suite files. Each has an unparsable
`font-family="Mplus 1p"` (the word starts with a digit), which usvg replaces
by Times New Roman and then `serif`. The old oracle then drew nothing for the
base font, and its per-character fallback differed. Under the harness mapping
the oracle matches what we already draw (T91/T101 rules).

### Per file (why each target still fails)

| file | resvg (harness) picks | we pick | cause |
|---|---|---|---|
| font-family/sans-serif, bold-sans-serif | Noto Sans (Bold) | Arimo (Bold), T106 Chromium | conflicts with T106 |
| font-family/serif | Noto Serif | Tinos | Chromium conflict + Noto Serif not embedded |
| font-family/fallback-1 (`Invalid`) | Noto Serif | Noto Sans + T98 warning | same, plus the T98 default |
| font-family/cursive | Yellowtail | Tinos | Chromium conflict + font not embedded |
| font-family/fantasy | Sedgwick Ave Display | Tinos | Chromium conflict + font not embedded |
| font-family/monospace | Noto Mono | DejaVu Sans Mono | Chromium conflict + font not embedded |
| font-family/source-sans-pro, font-list | Source Sans Pro | Noto Sans + warning (`suiteOnlyFamilies`) | font not embedded |
| font-stretch/extra-condensed, inherit, narrower | Noto Sans ExtraCondensed (`NotoSans-ExtraCondensed.ttf`, width 2) | Noto Sans Regular | face not embedded; `font-stretch` not parsed |

Kerning and shaping are not the cause in any of these files. In every case
the font differs. `noto-sans.svg`, `double-quoted.svg` and `fallback-2.svg`
draw the same word in Noto Sans and pass at 99.99%.

## Skipped (and why)

- **Generics → suite fonts in the renderer.** A given input has to resolve
  one way. Mapping `sans-serif` to Noto Sans would pass the two sans-serif
  files, but T106 measured it as worse for real-world charts (web-vega,
  plantuml). The other generics would also need fonts we do not embed. Only
  corpus sniffing could satisfy both references, and that is not acceptable.
  **Decision for Rowan:** either accept these 8 files as failing
  (Chromium-first for generics), or give them a Chromium reference in
  `criteria.csv`. I did not edit `criteria.csv`. Before T110 their Chromium
  scores were 98.9-99.2% (T106 report).
- **Fonts, reported and not added** (the task rule). All ship in the suite's
  `fonts/` with licence files there. The sizes are the Lean module output of
  `tests/gen_font_module.py --no-glyph-names`, with the default Latin ranges
  and with `--unicodes='*'` (how the Noto faces were embedded):

  | font | licence | TTF | Lean, Latin | Lean, `*` | files it would fix |
  |---|---|---:|---:|---:|---|
  | Source Sans Pro Regular | OFL 1.1 (Adobe, RFN "Source") | 290,156 | 45,370 | 193,561 | source-sans-pro, font-list (no Chromium conflict) |
  | Noto Sans ExtraCondensed | OFL 1.1 | 307,508 | 39,364 | 278,704 | 3 font-stretch files, plus parsing `font-stretch` and a stretch column in `FontSet.styles`/`FamilyMatch.pick` (fontdb matches stretch before style). About 1-2 h. |
  | Noto Serif Regular | OFL 1.1 | 552,144 | 54,388 | 357,872 | serif, fallback-1 (only with suite generics) |
  | Noto Mono Regular | OFL 1.1 (Apache 2.0 in older Noto releases) | 107,848 | 27,144 | 74,304 | monospace (only with suite generics) |
  | Yellowtail Regular | Apache 2.0 | 60,864 | 73,916 | 80,036 | cursive (only with suite generics) |
  | Sedgwick Ave Display | OFL 1.1 | 135,996 | 65,142 | 98,742 | fantasy (only with suite generics) |

  Recommendation: Source Sans Pro (+~0.2 MB) and Noto Sans ExtraCondensed
  plus `font-stretch` (+~0.3 MB) can be added without conflicting with
  Chromium. They would fix 5 of the 12 targets. The generic fonts only help
  if Rowan chooses resvg over Chromium for generics.
- **No `tests/svg/110_*.svg`.** The change is to the resvg-suite oracle
  only, which the local tests do not use.

## Report

Baseline at `13cac51`, after at
`4cdbc27`. `lake build` clean; `check-theorems.sh`: `invariants ok`,
`theorems ok`; `run_tests.py` 63/80 before and after, no file's
exact/within/within32 changed; `run_adversarial.py` 170/170 clean;
`run_tiles.py` 80/80 byte-identical. Wall time: fast pass 13 s → 12.2 s,
200 px 19.9 s → 20.1 s (within noise). No renderer code changed, so the
realworld-vs-Chromium numbers are unchanged by construction. That run was
skipped.

**resvg suite** (`run_corpora.py --corpus resvg --route direct`):

| width | pass before | pass after | pass→fail | fail→pass |
|---|---:|---:|---:|---|
| 100 (`--fast`) | 1543 / 1679 | 1548 / 1679 | 0 | the 5 below |
| 200 | 1567 / 1679 | 1572 / 1679 | 0 | the 5 below |

Newly passing (200 px within-8 before → after):
`text/writing-mode/japanese-with-tb` 94.03 → 99.99,
`text/textPath/complex` 95.13 → 99.62, `text/textPath/writing-mode=tb`
96.15 → 99.77, `text/writing-mode/tb-and-punctuation` 98.23 → 99.92,
`text/letter-spacing/non-ASCII-character` 98.44 → 99.88.

**Target files at 200 px** (within-8, %). The "before" reference for the
generic-family files was an empty frame:

| file | before | after |
|---|---:|---:|
| font-family/bold-sans-serif | 97.30 | 97.78 |
| font-family/cursive | 98.36 | 97.39 |
| font-family/fallback-1 | 97.99 | 97.41 |
| font-family/fantasy | 98.36 | 96.76 |
| font-family/font-list | 97.65 | 97.65 |
| font-family/monospace | 97.82 | 98.76 |
| font-family/sans-serif | 97.91 | 97.83 |
| font-family/serif | 98.36 | 97.16 |
| font-family/source-sans-pro | 97.65 | 97.65 |
| font-stretch/{extra-condensed,inherit,narrower} | 97.39 | 97.39 |

The other score that moved: `text/font/simple-case` 95.46 → 95.25, fail →
fail (no `font-family`, so the reference now draws Noto Serif).

## Open decision for the integrator / Rowan (after the T110 merge)

T118 covers Source Sans Pro, Noto Sans ExtraCondensed and `font-stretch`.
One item from this report is still open. The 8 generic-family suite files
(`text/font-family/{serif,sans-serif,bold-sans-serif,cursive,fantasy,monospace,fallback-1}.svg`)
cannot pass against resvg while generic families resolve Chromium-first
(T106, kept by T118). Choose one:
(a) accept them as known failures, or
(b) give them a Chromium reference in `tests/criteria.csv`. Their Chromium
scores were 98.9–99.2% before T110 (T106 report), so some may still need a
small fix to reach 99%.
