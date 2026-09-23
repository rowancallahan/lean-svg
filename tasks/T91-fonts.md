# T91 — broader script coverage with embedded OFL fonts  (branch `claude/feat-fonts`)

Rowan's decision (`docs/DECISIONS.md`): add fonts so non-Latin text renders.
Budget **up to 50 MB total added**, and **only fonts under the same licence
as the current embedded ones (SIL OFL 1.1, e.g. Noto)**. Emoji: not now.

Order:
1. **Cyrillic and Greek** first (Noto Sans covers them; extend the current
   subsets or embed the full Latin/Greek/Cyrillic Noto Sans regular, bold,
   italic). These should reuse the existing glyf parser as is.
2. **Other scripts by reach**: CJK, Devanagari, Arabic, Hebrew, Thai, etc.
   Measure each: file size, glyph format (`glyf` vs `CFF`/`CFF2`: our parser
   reads `glyf` only; prefer `glyf` builds of Noto where they exist),
   and whether it needs shaping (Arabic joining forms, Indic reordering).
   Implement what fits the rules; for scripts that need shaping, embed the
   font and render unshaped only if the output is still recognisably right,
   otherwise document and stop — do not write a shaper in this task.
3. **Font fallback**: when the requested family lacks a glyph, fall back
   through the embedded fonts in a fixed order (usvg does fallback; match
   its rules where they apply).

**Hard requirements:**
- The parser stays total (`LeanSvg/Font.lean`): fuzz every new font file
  like `tests/fuzz_font.py`, and check glyph outlines against fontTools like
  `tests/check_font.py`.
- **Build time and binary size.** Fonts are currently embedded as Lean
  source (`LeanSvg/Fonts/*.lean`). 50 MB of Lean byte-array literals may make
  `lake build` impractically slow or huge. Measure first with one large font;
  if it is bad, find a better embedding that stays pure and has no runtime IO
  (e.g. generating a compact representation, or compile-time inclusion) and
  document the choice. If nothing works within the rules, stop and write up
  the options for Rowan.
- Record each font's name, version, licence and source URL in a `NOTICE`
  or `LeanSvg/Fonts/README.md`, and keep the OFL licence text in the repo.
- Measure against the suite's text directories and the three files in
  `docs/resvg-wrong/R4-text-layout.md` group A (Cyrillic/CJK) before/after.
- No change to the effect layer; `render` stays pure.

---

## Common rules (every lean-svg agent)


**Branches (Rowan's rule).** Push only to the one branch this task names.
The integrator merges it into `claude/beautiful-brown-nd2o1h` and then
deletes it, so do not create any other branch, tag or pull request. You may
use subagents inside your own session for research or parallel work; they
must not push anywhere; you collect their work into your branch.

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
