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

## Addendum (integrator, after merging T98)

- Generic `sans-serif` (and `system-ui`) is a real match for Noto Sans, not
  a fallback: resolve it without a warning. `serif`, `monospace`, `cursive`,
  `fantasy` and unknown names keep T98's fallback + warning (no such faces
  are embedded).
- T98 made 10 resvg-rated-correct files go pass→fail because the harness's
  resvg run finds no font for generic families and draws nothing; see
  T98's report. Score those under T100's criteria (`tests/score_criteria.py`)
  and report both numbers.

---

## Spec implemented

**Two programs, one effect set (`LeanSvg/Effect.lean`).** `Op` is unchanged:
still the five T98 operations, with no print operation. The effect count in
`tests/check_invariants.py` stays at five, because no new op was needed.
- `renderProgram` is the default, strict program. It reads the input,
  refuses if the output path exists, and otherwise writes the PNG only. It
  never checks or writes `<out>.warnings.txt`. It returns
  `Except ε Bool` (were there warnings?) for the exit code. `render` has the
  same type as T98's (`ByteArray → Except ε (ByteArray × ByteArray)`), so
  `Main` passes the same pure function to both programs.
- `renderProgramWarn` is T98's two-file program, renamed only. Its
  definition, statements and proofs are unchanged.

**Theorems.** All 18 in `Effect.lean` depend on `[propext]` only.
- Strict: `renderProgram_spec`, `_no_clobber`, `_error_no_write`,
  `_ok_output` and `_ok_frame` are the pre-T98 one-file statements,
  including `ok_frame`'s single `q ≠ out` hypothesis. The one difference is
  the success payload: `render` also returns a warnings text, and the result
  is `.ok (warn.size != 0)` instead of `.ok ()`. `renderProgram_ok_output`
  therefore names `warn` as well. The proofs are the pre-T98 ones, except
  `ok_frame`: `runFS_frame` now needs `q ≠ warnPath out`, so `ok_frame` is
  proved from `_spec`. New: `renderProgram_never_overwrites`.
- `--warnings`: `renderProgramWarn_{spec, no_clobber, no_clobber_warnings,
  error_no_write, ok_output, ok_warnings, ok_no_warnings, ok_frame,
  never_overwrites}`. These are T98's theorems, renamed. `ok_frame` says it
  writes at most the two paths; `never_overwrites` says it never overwrites.
- `runFS_frame`, `runFS_input_only` and `warnPath_ne` are unchanged.

**`Main.lean`.** It writes nothing to stdout or stderr: the usage text,
`lean-svg: error: …` and T98's stderr note are all gone. The usage text now
lives in the file's doc comment and in the README. `--warnings` may appear
anywhere in the arguments. Exit codes:
- `0`: success, no warnings.
- `2`: success with warnings. In strict mode they are dropped and this code is
  the only signal.
- `1`: every failure, with nothing written. That covers bad arguments
  (including a missing output argument, which used to exit 2), unreadable
  input, an existing output (or, under `--warnings`, an existing warnings
  file), a render error, and an `IO` error from `execIO`.

I did not add distinct failure codes. The task says a bad command line is
`1`, and one code is the simplest thing to document. `execIO` is wrapped in
`try … catch _ => return 1`, because an uncaught `IO` error would make the
Lean runtime print `uncaught exception: …` to stderr. This is the only error
handling added.

**Checkable (`tests/check_invariants.py`, check 5 `no-output`).** It checks:
- the `lean-svg` exe root is `Main`;
- `Main.lean` imports only `LeanSvg`;
- with comments and strings stripped, `Main.lean`, `LeanSvg.lean` and
  `LeanSvg/**/*.lean` never mention `print`/`println`/`eprint*`/`putStr*`,
  `getStdout`/`getStderr`/`setStdout`/`setStderr`/`stdout`/`stderr`,
  `dbg_trace*`/`dbgTrace*`, `panic*` or `Process*`.

It fails on the old `Main.lean`: all four `IO.eprintln` lines are flagged.
The dev tools (`FontDump`, `ShapeDump`, …) are separate roots, so they are
exempt. I also fixed an existing bug in `strip_comments_and_strings`: it
copied `--` comments through instead of blanking them. The check stops
nothing that passed before.

**Addendum.** In `Svg.resolveFontFamily`, the unquoted generics `sans-serif`
and `system-ui` now resolve to Noto Sans (index 0), so they raise no warning.
The text was already drawn with index 0 as the fallback, so pixels are
identical. `serif`, `monospace`, `cursive`, `fantasy` and unknown names keep
the fallback and the warning.

**Tests.**
- `tests/check_warnings.py` was rewritten. It covers:
  - strict with warnings: one file, exit 2;
  - `--warnings` with warnings: two files, exit 2, a deduplicated line;
  - no warnings: one file, exit 0, in both modes, including `sans-serif`,
    `system-ui` and `Foo, sans-serif`. `serif` still gives exit 2;
  - the 32-line bound;
  - no-clobber on the PNG in both modes, and on the warnings file under
    `--warnings`. Strict ignores an existing warnings file and leaves it
    untouched;
  - bad arguments, unreadable input and an unwritable output: exit 1,
    nothing written;
  - every run has empty stdout and stderr.
- These harnesses now treat exit 2 as success: `run_tests.py`,
  `run_corpora.py`, `run_tiles.py`, `run_sizes.py`, `check_hsl.py`,
  `gen_strokes.py`, `gen_a3_report.py`, `make_human_review.py` and
  `playground/server.py`.
- `run_adversarial.py` now requires empty stdout/stderr, accepts exit
  0/1/2 (a PNG exists iff the code is 0 or 2), allows only `out.png` in the
  output dir, and requires a second render into an existing file to exit 1.

**Skipped.** No `tests/svg/98b_*.svg`. The feature is CLI behaviour, which
`check_warnings.py` covers. A `sans-serif` render would fail against the
harness's resvg, which draws nothing for generic families.

## Report

All gates below were run on the final tree. Baselines came from the
pre-change binary at commit `1d5fb43`.

| gate | result |
|---|---|
| `lake build` | clean, no warnings |
| `scripts/check-theorems.sh` | `theorems ok`; Effect.lean 18 theorems, all `[propext]` |
| resvg suite, fast 100 px (1679) | 1552 → 1552 pass; 0 files changed status or within-8 |
| resvg suite, 200 px (1679) | 1576 → 1576 pass; 0 files changed status or within-8 |
| `run_tests.py` (71) | 60 → 60 pass; every field except timings identical |
| `run_adversarial.py` | 147/147 clean (stricter: stdout/stderr must be empty) |
| `run_tiles.py` | 71/71 byte-identical |
| `check_warnings.py` | `warnings ok` |

At both widths, 15 corpus files now exit 2 (strict, with warnings). Every
harness scores them as rendered.

**The 10 files T98 moved pass→fail (addendum).** Each was checked against
three references, at 200 px, before and after this task:
- Live resvg (headline): 0/10 pass before and after. Harness resvg draws
  nothing for generic or unknown families.
- T100 criteria (`tests/score_criteria.py`): 0/10 pass before and after. Nine
  are scored against resvg and fail as above.
  `writing-mode/tb-and-punctuation` is scored against Chrome and fails
  (within-8 97.2%). Overall, criteria scoring is unchanged: 1468 pass,
  55 fail, 110 missing, 112 unreviewed. I produced the Chrome CSV only for
  `text/{font-family, writing-mode, letter-spacing}`, so the other
  Chrome-referenced files count as missing.
- Rated-correct suite PNGs (`--ref suite`): 0/10 before and after. Within-8
  is 97.2–98.6%, identical before and after.

This task changes no pixels, so none of these numbers could move. Making
`sans-serif` a real match removes the warning (exit 0 instead of 2) for
`font-family/sans-serif` and `bold-sans-serif`. It does not change their
scores.
