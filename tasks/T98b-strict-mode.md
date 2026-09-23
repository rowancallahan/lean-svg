# T98b — Strict mode vs `--warnings`  (branch `claude/feat-strict-mode`; starts after T98 is merged)

Rowan's follow-up to T98 (font fallback with a warnings file):

- **Default is strict**: one file in, one file out, no clobber. The existing
  theorems for this path stay exactly as they are (same statements; keep
  proofs as unchanged as possible). No warnings file is ever written.
- **`--warnings` opts in** to writing `<output>.warnings.txt` when there are
  warnings: at most two files out, both no-clobber (T98's behaviour). Its
  theorem: writes at most these two paths, never overwrites.
- **Exit codes** distinguish the outcomes: `0` success, no warnings; `2`
  success with warnings (PNG written; in strict mode the warnings are
  dropped, the exit code is the only signal); `1` failure (nothing written,
  as today). Document them in the README.
- **No stdout or stderr, ever** (Rowan: "it should only go from the input
  files to the output files with no side effects, except for the exit
  codes"). Reason: a text channel driven by input content (e.g. a font name
  echoed in a message) is an unreasoned-about output. Remove every
  stdout/stderr write from the `lean-svg` binary, including T98's stderr note
  and today's error messages (`lean-svg: error: ...`) and usage text: a bad
  command line is exit code `1`. Failures are reported by exit code only; a
  small fixed set of distinct failure codes (bad arguments, unreadable input,
  output exists, render failed) is fine if documented. The only place
  warning text may go is `<output>.warnings.txt` under `--warnings`.
  Make it checkable: the effect layer has no print op, and
  `tests/check_invariants.py` fails if the `lean-svg` main path can write to
  stdout/stderr (dev tools such as `fontdump`/`shapedump` are exempt).
  Update `tests/*.py` that parse the old messages to use exit codes.
- Axioms stay `[propext]` only; `scripts/check-theorems.sh`,
  `tests/check_invariants.py` pass; update the effect count there only if
  the new op requires it, and say so.
- Tests: strict with warnings (one file, exit 2), `--warnings` with warnings
  (two files, exit 2), no warnings (one file, exit 0), no-clobber for both
  files.

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
