# Task protocol

## Conduct (Rowan's rules for every agent, read first)

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


One markdown file per task. An agent picks up a task by reading its file,
doing exactly what it says, and appending a `## Report` section at the bottom
with: what changed (files), before/after numbers from the named commands, and
anything it could not do. Reports are the paper trail; keep them factual.

Invariants that apply to every task touching `LeanSvg/*.lean`:

1. No `partial`, no `unsafe`, no `@[extern]`, no `panic!`, no `!`-indexing
   (`arr[i]!`, `get!`, `set!`). Use `getD` / `setIfInBounds` or carry proofs.
2. No `Float` anywhere. Fixed point only (`Fx = Int`, 1/256 px; matrices 16.16).
3. Every loop is a `for` over a finite range bounded by the input size or a
   constant. If you need recursion, use fuel that is structurally decreasing.
4. Hot loops in `Nat` (Lean's unboxed `Int` is 31-bit; `Nat` is 63-bit).
5. `lake build` must finish with no errors and no new warnings.
6. `LeanSvg/Effect.lean` is off limits unless the task is about it.
7. Do not commit. Do not touch `tests/out/`.
8. Shell commands: one step per line with `&& \` continuations, never a long
   single-line `&&` chain (the user reads them in the tool display).
9. Keep the verification loop short: byte-identity at natural size plus
   `--width 800`; timings at `--width 1600` or smaller, median of 3; run each
   harness once. No 3200 or 4000 px renders unless a task explicitly needs
   them. Iterate fast, report what you measured.

Verification commands:

```bash
lake build
python3 tests/run_tests.py            # fidelity vs resvg, all corpus files
python3 tests/run_adversarial.py      # must stay N/N clean (N scales with tests/svg/*.svg)
```
