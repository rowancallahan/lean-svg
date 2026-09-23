# T93 — Arabic, Hebrew and Devanagari: bidi and shaping  (branch `claude/feat-shaping`)

Rowan wants these scripts to render correctly. T91 (read its report in
`tasks/T91-fonts.md`) embedded fonts for many scripts but stopped at these
three because they need:

1. **Bidi (RTL)** for Arabic and Hebrew: a bounded, total implementation of
   the Unicode Bidirectional Algorithm subset that SVG text needs (UAX #9:
   resolve levels per paragraph = per text chunk, the `direction` and
   `unicode-bidi` properties, mirroring of paired brackets). Match usvg/
   rustybuzz behaviour where resvg renders these correctly, else Chromium.
   Also covers `text/direction/rtl.svg` and `text/unicode-bidi/*`.
2. **Arabic shaping:** joining forms (isolated/initial/medial/final) and
   the mandatory lam-alef ligatures, driven by the font's `GSUB` (`init`,
   `medi`, `fina`, `isol`, `rlig`) with the Unicode joining-type table.
   Mark positioning via `GPOS` mark-to-base if the font needs it.
3. **Devanagari (Indic) shaping:** the minimum for recognisably correct
   text: pre-base matra reordering (e.g. `ि`), reph, conjuncts/half forms via
   the font's `GSUB` (`akhn`, `rphf`, `half`, `pres`, `abvs`, `blws`, `psts`).
   Follow HarfBuzz's Indic shaper behaviour; a subset is fine, document it.

Fonts: Noto Sans Arabic (or Amiri from the suite), Noto Sans Hebrew, Noto
Sans Devanagari: OFL only, `glyf` builds, added the same way T91 added fonts
(`tests/gen_font_module.py`, `LeanSvg/Fonts/README.md`, `NOTICE`, licences).

**Ownership, to keep merges clean** (another agent, T94, is changing how
fonts are embedded and loaded concurrently): put your code in new modules,
`LeanSvg/Bidi.lean`, `LeanSvg/Shape.lean` (GSUB/GPOS lookups beyond the
existing pair kerning) and small hooks in `Text.lean`/`Font.lean`. Do not
change `LeanSvg/Fonts/*` embedding or `Font.base64Decode`; add your font
modules with the existing generator exactly as T91 did.

Everything total and bounded (lookup recursion depth, glyph-sequence growth
cap per run, fuzz the new GSUB/GPOS parsing like `tests/fuzz_font.py`).
Measure: the resvg suite's text directories plus new `tests/svg/93_*.svg`
files for each script, against resvg where resvg is rated correct, else
Chromium. If a piece turns out to be very large, finish the others, push,
and write up what remains and why.

---

## Common rules (every lean-svg agent)


**Branches (Rowan's rule).** Push only to the one branch this task names.
The integrator merges it into `claude/beautiful-brown-nd2o1h` and then
deletes it, so do not create any other branch, tag or pull request. You may
use subagents inside your own session; they must not push anywhere.

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
