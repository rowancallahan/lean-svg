# T59 — max input size and no-clobber theorems  (branch `claude/feat-noclobber`)

Two items from `PLAN.md` M3b and `ROADMAP.md` §3d, in this order:

1. **M3b.4 max input size.** `render` rejects `inp.size > maxInput` (64 MiB
   unless the code already has a limit — check `Xml`/`Render`) before
   parsing. Theorem `render_rejects_large : inp.size > maxInput → ∃ e,
   render opts inp = .error e`. Put it next to the other public theorems
   and add it to `scripts/check-theorems.sh`.
2. **M3b.1 no-clobber**, the centrepiece. Read PLAN.md M3b.1 carefully and
   implement exactly that: model `FS := String → Option ByteArray`, add
   `Op.outputExists` (`Res = Bool`), program = read input; if output exists
   fail with a clear error; else render and write. Re-prove all six existing
   effect theorems against the new model (generalise `runFS_input_only` to
   "depends only on `fs inp` and whether `fs out` is present"), add
   `renderProgram_no_clobber : fs out = some b → (run …).2 = fs`. The trusted
   `execIO` gains one `System.FilePath.pathExists` call on the output path
   only. Update `Main.lean` if needed (a `--force` flag is **not** wanted).
   All effect theorems must still depend on `[propext]` only. Update
   `SPEC.md`, `DESIGN.md` §1 and `README.md` where they state the theorems.
   Update `scripts/check-theorems.sh` with the new theorem names and
   `tests/run_*.py` if they rely on overwriting an existing output file
   (they probably do — make them delete the output first).

`LeanSvg/Effect.lean` is in scope for this task only. Another agent (T43) is
concurrently writing CI around the theorem list; keep theorem names stable
where you can.

---

## Common rules (every lean-svg agent)

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
3. Full corpus with delta table:
   `python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after --no-worst --compare /tmp/base/resvg_direct.csv`
   **Zero files may go from pass to fail.** Investigate any file whose
   within-8 score drops.
4. `python3 tests/run_tests.py` — no file's score drops; `python3 tests/run_adversarial.py` all clean;
   `python3 tests/run_tiles.py` byte-identical.
5. Add at least one small `tests/svg/NN_<feature>.svg` exercising the feature
   if it fits the local corpus style (pick an unused number; collisions with
   other agents are resolved by the integrator).

**Deliverable:** write `tasks/<ID>-<slug>.md` (the ID given below) with the
spec you implemented, what you skipped and why, and a `## Report` with the
before/after numbers for your target directories and the whole suite.
Commit (author `Rowan Callahan <rowan.l.callahan@gmail.com>`) in logical
commits and push to your assigned branch. **Do not open a pull request, do not
merge, do not push to any other branch.** If you run out of time, push what
is verified-clean and document what remains. Aim to finish within a few
hours; partial but regression-free beats complete but risky.
