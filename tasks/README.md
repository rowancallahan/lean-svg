# Task protocol

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
