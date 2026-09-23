# T43 — CI that enforces the proof boundary  (branch `claude/feat-ci-invariants`)

Do `tasks/T43-ci-proofs.md` as written, with these amendments:
- `scripts/check-theorems.sh` already exists as a stopgap; extend or replace
  it so the CI job calls one script. It must also cover the theorems in
  `proofs/SizeBound.lean` (which legitimately use `Classical.choice` and
  `Quot.sound` — allow exactly the standard three axioms there, `[propext]`
  only for the six effect theorems).
- The CI `tests` job must install Lean the way `scripts/cloud-setup.sh` does
  if `release.lean-lang.org` is the problem there too; on GitHub runners elan
  normally works, so prefer the standard elan install there.
- Also add a check that every new `theorem` under `proofs/` and
  `LeanSvg/Effect.lean` is covered by the axiom audit (e.g. generate the
  `#print axioms` list from the sources), so a new theorem cannot silently
  escape it.
- Do not open a PR (ignore that part of T43); commit and push to your branch.
- Show each check failing when broken, as T43 requires.

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

## Report

Implements T43-ci-proofs.md with the T43b amendments. No renderer changes;
`git diff origin/main -- LeanSvg/` is empty.

### Files

- `scripts/axiom_audit.py` (new) — check 1. Scans `proofs/*.lean` (skipping
  `*-wip.lean`) and `LeanSvg/Effect.lean` for `theorem` declarations,
  tracking `namespace`/`end` to build fully-qualified names, instead of a
  hand-maintained list — a new theorem is picked up automatically, which is
  what T43b's coverage requirement asked for. For each file it elaborates a
  `#print axioms` per discovered theorem and checks the reported axiom set:
  the six `LeanSvg/Effect.lean` theorems must be *exactly* `[propext]`;
  `proofs/*.lean` theorems may be *any subset* of `{propext, Classical.choice,
  Quot.sound}` (some helper lemmas there use none of the three). `sorryAx` or
  anything else fails immediately, and so does an elaboration error.
- `tests/check_invariants.py` (new) — checks 2-4.
  - **Two effects**: elaborates `match op with | .readInput => () |
    .writeOutput _ => ()` with no wildcard arm against the real `Op`. A
    constructor added, removed, or renamed fails to compile ("Missing
    cases" / unknown identifier). What it misses, per T43's ask: if a
    constructor is added *and* every match site in the codebase (including
    this one) is updated with a new arm in the same change, this check
    passes along with the rest — it only catches an *incomplete* update, not
    a deliberate, complete one. That's the same thing a reviewer would have
    caught by reading the diff, which is what it's replacing.
  - **No IO outside the effect layer**: strips `--`/`/- -/` comments and
    `"..."` string literals (positions preserved so line numbers stay
    correct in the failure message), then searches `LeanSvg/*.lean` other
    than `Effect.lean` for `IO.` with a word boundary before it (so `FIO.`
    doesn't false-positive). Comment-stripping was necessary: several doc
    comments in `Bytes.lean`/`Css.lean`/`Render.lean` already say the word
    `partial` in prose, and would trip check 4 without it.
  - **Mechanical invariants**: same stripped text, across all of
    `LeanSvg/*.lean` (including `Effect.lean` — these apply everywhere,
    unlike the IO check), for `partial`, `unsafe`, `@[extern]`, `panic!`,
    `Float` (all word-bounded) and `!`-indexing (`]!`, `get!`, `set!`).
- `scripts/check-theorems.sh` (rewritten) — now the single script the CI
  `invariants` job calls: runs `axiom_audit.py` then `check_invariants.py`
  and fails if either does.
- `scripts/install-lean.sh` (new) — shared by `cloud-setup.sh` and CI. Tries
  the standard `elan toolchain install`, and only falls back to unpacking the
  GitHub release zip and `elan toolchain link` (cloud-setup.sh's old
  unconditional method) if that fails, which is what happens in this
  sandbox: `elan toolchain install` here returns `[56] ... CONNECT tunnel
  failed, response 403` against its toolchain download, confirming the
  existing comment about `release.lean-lang.org` being blocked by the egress
  proxy. On a GitHub-hosted runner the first branch is expected to succeed.
- `scripts/cloud-setup.sh` — now delegates the Lean-install portion to
  `install-lean.sh` instead of duplicating it; everything else (resvg/usvg,
  numpy/pillow, the resvg-test-suite clone, the first build) unchanged.
- `.github/workflows/ci.yml` (new) — two jobs, `invariants` gating `tests`
  (`needs: invariants`):
  - `invariants`: checkout, cache `~/.elan` and `.lake`, `install-lean.sh`,
    `lake build`, `bash scripts/check-theorems.sh`. No resvg, no corpora.
  - `tests`: additionally caches and installs resvg/usvg 0.48.1 (`cargo
    install --locked`, matching cloud-setup.sh's pinned versions), clones
    `linebender/resvg-test-suite` shallowly into
    `tests/corpora/resvg-test-suite` (the same source `cloud-setup.sh`
    already uses — not `linebender/resvg` symlinked, which is what T43's
    original text says but does not match how `run_tests.py` actually locates
    `RESVG_FONTS_DIR`), then `lake build`, elaborates every `tests/*.lean`,
    and runs `run_tests.py`, `run_tiles.py`, `run_adversarial.py`.
  - Triggers on `push` and `pull_request`; a fork-PR guard is in place on
    both jobs even though nothing here uses secrets yet.
  - Validated with `actionlint` v1.7.7 (downloaded for this session): clean,
    no findings.

### Verify: each check fails when broken

All four demonstrated locally, then reverted (`git status` clean
afterwards):

- **Third `Op` constructor.** Added `| doNetworkCall` to the real `Op`.
  `lake build` itself fails first, with five "Missing cases" / "Alternative
  ... has not been provided" errors across `Op.Res`, `runFS`, `execIO` and
  the `runFS_frame`/`runFS_input_only` proofs — a stronger, earlier gate
  than check 2 alone. To confirm check 2's own technique independently
  (in case those other sites had wildcard arms and silently tolerated a
  third constructor), the same match-with-no-wildcard pattern against a
  throwaway 3-constructor inductive in isolation:
  ```
  error: Missing cases:
  FakeOp.doNetworkCall
  ```
- **`IO.println` outside `LeanSvg/`.** Added `def _debugPrint : IO Unit :=
  IO.println "debug"` to the top of `LeanSvg/Render.lean`:
  ```
  AssertionError: FAIL [no-io]: IO. found outside Effect.lean:
  LeanSvg/Render.lean:2: def _debugPrint : IO Unit := IO.println
  ```
- **`sorry`.** Replaced `size_be32`'s proof in `proofs/SizeBound.lean` with
  `by sorry`. `lake build` still succeeds (a `sorry` compiles), but the
  audit catches it — and everything downstream of the lemma too, since
  `sorryAx` propagates through the axiom sets of every theorem that uses it:
  ```
  FAIL [proofs/SizeBound.lean]: 'LeanSvg.Png.SizeBound.size_be32' depends on
  axioms ['propext', 'sorryAx'], allowed only a subset of
  ['Classical.choice', 'Quot.sound', 'propext']
  ```
- **`partial def`.** Added `partial def _loopForever (n : Nat) : Nat :=
  _loopForever n` to `LeanSvg/Raster.lean`:
  ```
  AssertionError: FAIL [mechanical]: forbidden construct found:
  LeanSvg/Raster.lean:1: forbidden partial: partial def _loopForever ...
  ```

### Before/after numbers

No renderer changes, so these are the same before and after — recorded once,
against the current `origin/main` tree plus this branch's CI-only diff:

- `lake build`: 45/45 jobs, no errors, no warnings. Cold (`.lake/build`
  removed): 27.5s. Warm (unchanged): 0.16s.
- `bash scripts/check-theorems.sh`: passes, 2.9s — 6 theorems audited in
  `LeanSvg/Effect.lean`, 15 in `proofs/SizeBound.lean`, plus the two-effects/
  no-IO/mechanical checks.
- `resvg`/`usvg` 0.48.1 via `cargo install --locked`: cold (removed from
  `~/.cargo/bin` first) 35.4s + 29.4s = ~65s combined; warm (cache hit,
  binaries already present) effectively instant (~0s beyond the cache
  restore itself).
- `python3 tests/run_tests.py`: **23/27 passed, 4 failed** — `12_badge`,
  `14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`. This is the
  current state of `origin/main`, not something this branch introduced or
  can fix under "no renderer changes"; flagging it below.
- `python3 tests/run_tiles.py`: 27/27 files byte-identical, timing checks
  ran.
- `python3 tests/run_adversarial.py`: 61/61 cases clean, 0 violations.
- `tests/CssTests.lean`, `tests/PngSizeTests.lean`: both elaborate silently.

### Known issue to flag for the integrator

Because `run_tests.py` exits nonzero on a fidelity failure (verified: exit
code 1 with the 4 failures above), the new `tests` CI job **will show red on
`main` right now**, independent of this branch — it is correctly reporting 4
pre-existing renderer regressions, not a bug in the workflow. Weakening the
threshold or skipping those files to force green was explicitly out of scope
("No renderer changes") and would hide real regressions from the team, so I
left check 5 as specified. This should go green once whichever other task
owns `12_badge`/`14_flower_transforms`/`15_spiral_stroke`/`16_stress_2000`
lands. The `invariants` job is green on `main` today.

### Not done / deferred

- Did not open a pull request, per the T43b amendment overriding T43's
  original instruction.
- Have not seen an actual GitHub Actions run of this workflow (only local
  reproduction of every step plus `actionlint`), since triggering one
  requires pushing to `claude/feat-ci-invariants` — done as the final step
  of this task. If CI infrastructure notifications are available afterward,
  worth a follow-up glance to confirm the hosted run matches these numbers,
  particularly the cache hit/miss behavior on a second push.
