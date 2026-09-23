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

---

## What was implemented

Both items, in the order given.

### 1. Max input size (M3b.4)

`LeanSvg/Render.lean`: `def maxInput : Nat := 64 * 1024 * 1024` next to
`maxDim`/`maxPixels`, and `render`'s first line is now
`if input.size > maxInput then throw s!"input {input.size} bytes exceeds the {maxInput} byte limit"`,
before `Xml.parse` runs. No existing limit on raw input bytes was found
(`Xml.maxElements`/`maxDepth` bound structure, not size), so 64 MiB is a new
cap, as suggested.

Theorem `render_rejects_large`, added to `proofs/SizeBound.lean` next to
`render_output_size_bound`/`render_size_le_const` (the other public theorems
about `render`), not to `Effect.lean`, which this task's other half restricts
to no-clobber only:

```lean
theorem render_rejects_large (opts : Options) (input : ByteArray) (h : input.size > maxInput) :
    ∃ e, render opts input = .error e
```

One line of tactic script (`split`, close the true branch by `rfl`, the false
branch is absurd by `omega` against `h`), exactly as cheap as M3b.4 promised.
`render_output_size_bound`'s proof needed one extra `split at hr` /
`· simp at hr` pair for the new check ahead of its existing `cases hp :
Xml.parse input with`; no other change to that proof, and the bound it proves
(67,452,996 bytes on success) is unaffected since the new check only adds an
error path.

### 2. No-clobber (M3b.1), the centrepiece

`LeanSvg/Effect.lean`:

- `FS := String → ByteArray` became `FS := String → Option ByteArray`
  (`none` = absent). `FS.write` now writes `some b`.
- `Op` gained a third constructor, `outputExists`, `Res = Bool`.
- `runFS` gained the corresponding case: `.step .outputExists k, fs =>
  runFS inp out (k (fs out).isSome) fs`. The existing `readInput` case reads
  `(fs inp).getD ByteArray.empty` — a missing input still reads as empty in
  the model, unchanged in spirit from before; a real missing-file read still
  raises an uncaught `IO` error in `execIO`, outside `Prog`, exactly as
  before this task (not something either model could or was asked to fix).
- `renderProgram` now takes a `clobberError : ε` and reads, checks
  `outputExists`, and only then runs `render` and writes:
  ```lean
  def renderProgram (clobberError : ε) (render : ByteArray → Except ε ByteArray) :
      Prog (Except ε Unit) :=
    .step .readInput fun inp =>
      .step .outputExists fun outExists =>
        if outExists then .pure (.error clobberError)
        else match render inp with
          | .ok png => .step (.writeOutput png) fun _ => .pure (.ok ())
          | .error e => .pure (.error e)
  ```
  This is the exact order PLAN.md M3b.1 specifies (read input; if output
  exists fail; else render and write) — the input is always read even when
  the output turns out to exist, but the pure `render`/parse only runs once
  no-clobber has cleared.
- All six existing theorems re-proved against the new model; one new
  theorem added, all seven still depend on `[propext]` only
  (`bash scripts/check-theorems.sh` and `lake env lean` audit both confirm):
  - `runFS_frame` — unchanged statement, extra trivial case for `outputExists`.
  - `runFS_input_only` — **generalised** exactly as asked: hypotheses are now
    `fs inp = fs' inp` (full agreement on the input) and
    `(fs out).isSome = (fs' out).isSome` (agreement only on *presence* of the
    output, since that's all a program can query).
  - `renderProgram_spec` — now `if (fs out).isSome then (.error
    clobberError, fs) else <same match as before>`.
  - `renderProgram_no_clobber` (new): `fs out = some b → (runFS ... p fs).2 =
    fs` — literally the whole filesystem unchanged, not merely "every path
    but `out`", because the program refuses before doing anything else.
  - `renderProgram_error_no_write`, `renderProgram_ok_output`,
    `renderProgram_ok_frame` — same statements as before, each with an added
    `fs out = none` hypothesis (a success or an ordinary render error can only
    be reached once no-clobber has let the program past its first check).
    `renderProgram_ok_output`'s conclusion changed from `= png` to `= some
    png` to match the `Option ByteArray` codomain.
- `execIO` gained exactly one call, `out.pathExists` (`System.FilePath.pathExists`),
  mapped from the new `outputExists` op. Still only reads/checks/writes the
  two given paths.

`Main.lean`: builds a `clobberError := s!"refusing to overwrite existing file
{out}"` and passes it to `renderProgram`. No `--force` flag, as directed.

**Input ≠ output (M3b.0) falls out for free**, as PLAN.md predicted:
`lean-svg a.svg a.svg` reads `a.svg`, then asks whether `a.svg` (now playing
the role of `out`) exists — it does, since it was just read — and refuses.
Verified manually (see Report).

### Test-script fallout: reused output paths

No-clobber breaks any script that renders into the same path twice without
deleting it first. `tests/run_tests.py` and `tests/run_corpora.py` already
delete stale output before each render and needed no change. Three places
did not and were fixed:

- `tests/run_tiles.py`: `render()` now unlinks `out` before invoking the
  binary. This is the single choke point `render_rgba` and every caller
  (`check_stitch`'s quadrant loop, `check_off_document`, `check_partial`,
  `time_tile`'s `TIMING_REPEATS` loop) go through, so one fix covers all of
  them — they all reuse a handful of fixed filenames (`full.png`,
  `tile.png`, `off.png`, `part.png`, `timing.png`) across many renders on
  purpose.
- `tests/run_sizes.py`: `time_runs` gained an optional `out_path` argument,
  unlinked before each of its `runs` iterations; `measure_baseline` (reruns
  into `b_ours.png`/`b_ref.png`) and `run_cell` (reruns into
  `<stem>_<width>_ours.png`/`..._ref.png`) now pass it.
- `docs/readme/render.py` (outside `tests/`, not in the mandatory checklist,
  but silently broken by this change otherwise since its output paths are
  the *committed* README images): `run()` gained the same `out_path`
  parameter. Ran it to confirm the fix works, then reverted the regenerated
  PNGs with `git checkout` so this task doesn't carry an unrelated image
  diff — only the script change is kept.

`tests/run_adversarial.py` needed no fix (every case gets its own fresh
`tempfile.mkdtemp()` directory, so no path is ever reused across cases), but
gained two new cases described below.

### Adversarial coverage for both features

Item 5 of the common rules ("add a `tests/svg/NN_*.svg` if it fits the local
corpus style") does not fit here: no-clobber and the input-size cap are CLI/IO
behaviour, not something a rendered SVG corpus file exercises — every
existing corpus file renders exactly as before (see Report). Instead, two
cases were added to `tests/run_adversarial.py`, in its own idiom (fresh
tmpdir, rc ∈ {0,1}, no stray files):

- `check_no_clobber`: render once (must succeed), record the output bytes,
  render again into the same path (must fail, rc ≠ 0), and check the file's
  bytes are byte-for-byte unchanged and no stray file appeared.
- `check_max_input_size`: write a 64 MiB + 1 byte file and confirm it is
  rejected (rc ≠ 0) through the same generic checks `run_case` already
  applies to every other hostile input (exit code, no crash markers, output
  existence matching the exit code, no stray files).

Both run in well under a second and are included in the default (unfiltered)
run of `run_adversarial.py`.

### What was not done / out of scope

- M3b.2 (output size bound) and M3b.3 (bounded work) are separate PLAN.md
  items, already done/dropped respectively (`proofs/SizeBound.lean`,
  `ROADMAP.md` §3d); not touched here.
- The TOCTOU gap between `execIO`'s `pathExists` check and the later
  `writeBinFile` (another process could create the output file in between)
  is inherent to any check-then-write pattern without an atomic
  create-exclusive primitive in Lean's `IO.FS`, is outside what the model
  proves (which treats the check as atomic with the rest of the program),
  and is documented as such in `SPEC.md` rather than fixed — introducing a
  new syscall dependency for `O_EXCL` was judged out of scope for this task.
- `learn/hello-effects/Step3NoClobber.lean` (the standalone teaching
  exercise PLAN.md/ROADMAP.md refer to) does not exist in this checkout
  (`learn/` is gitignored and not present on disk) and was not created;
  out of scope for a task about the main renderer's model.

---

## Report

### Baseline (before this change; stash of a clean working tree)

```
python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/base --no-worst
-- selected 1679 file(s) for resvg / direct: all 1679 files, rendered at --width 100
   5.8s  rendered 1672/1679  unsupported 4  size-mism 0  pass 835 (49.7% of all, 49.9% of rendered)

python3 tests/run_tests.py
23/27 passed, 4 failed, 0 render errors  (tol=8, threshold=0.990)
(failures: 12_badge, 14_flower_transforms, 15_spiral_stroke, 16_stress_2000 — pre-existing, unrelated to this task)

python3 tests/run_adversarial.py
61/61 cases clean, 0 with violations

python3 tests/run_tiles.py --no-timing
27/27 files: quadrant tiles stitch byte-identically to the full render
```

### After

```
lake build
Build completed successfully (45 jobs) — no errors, no new warnings.

bash scripts/check-theorems.sh
theorems ok
  (all 7 Effect.lean theorems: [propext] only
   render_rejects_large, render_output_size_bound, render_size_le_const,
   Png.SizeBound.encode_size_le_square: [propext, Classical.choice, Quot.sound]
   or [propext, Quot.sound] as before — unchanged axiom sets)

python3 tests/run_corpora.py --fast --corpus resvg --route direct --out /tmp/after \
    --no-worst --compare /tmp/base/resvg_direct.csv
   5.8s  rendered 1672/1679  unsupported 4  size-mism 0  pass 835 (49.7% of all, 49.9% of rendered)
== change vs baseline: 0 file(s) moved by more than 0.1 points of within-8.
newly passing 0 - newly failing 0 - unchanged 1679 - only in this run 0 - only in baseline 0

python3 tests/run_tests.py
23/27 passed, 4 failed, 0 render errors  (tol=8, threshold=0.990)
(same 4 pre-existing failures; per-file within-8/exact scores identical to
 baseline for all 27 files — diffed programmatically against the saved
 baseline results.json, 0 changed)

python3 tests/run_adversarial.py
63/63 cases clean, 0 with violations   (+2: no_clobber, oversized_input)

python3 tests/run_tiles.py
27/27 files: quadrant tiles stitch byte-identically to the full render
(interactive-tile timing section, which repeats into one fixed path, also now
 runs clean instead of failing on its second repeat — the run_tiles.py fix)
```

### Manual CLI verification

```
$ lean-svg tests/svg/01_triangle.svg /tmp/t.png ; echo $?
0
$ lean-svg tests/svg/01_triangle.svg /tmp/t.png ; echo $?
lean-svg: error: refusing to overwrite existing file /tmp/t.png
1
$ cp tests/svg/01_triangle.svg /tmp/same.svg
$ lean-svg /tmp/same.svg /tmp/same.svg ; echo $?
lean-svg: error: refusing to overwrite existing file /tmp/same.svg
1
```

Rendering fidelity, tile byte-identity and the theorem/axiom set are all
unaffected: this task only adds a check that runs *before* parsing (input
size) and one that runs *before* rendering (output existence), so every
success path is byte-for-byte what it was before.
