# Task protocol

One markdown file per task. An agent picks up a task by reading its file,
doing exactly what it says, and appending a `## Report` section at the bottom
with: what changed (files), before/after numbers from the named commands, and
anything it could not do. Reports are the paper trail; keep them factual.

Invariants that apply to every task touching `MicroSvg/*.lean`:

1. No `partial`, no `unsafe`, no `@[extern]`, no `panic!`, no `!`-indexing
   (`arr[i]!`, `get!`, `set!`). Use `getD` / `setIfInBounds` or carry proofs.
2. No `Float` anywhere. Fixed point only (`Fx = Int`, 1/256 px; matrices 16.16).
3. Every loop is a `for` over a finite range bounded by the input size or a
   constant. If you need recursion, use fuel that is structurally decreasing.
4. Hot loops in `Nat` (Lean's unboxed `Int` is 31-bit; `Nat` is 63-bit).
5. `lake build` must finish with no errors and no new warnings.
6. `MicroSvg/Effect.lean` is off limits unless the task is about it.
7. Do not commit. Do not touch `tests/out/`.

Verification commands:

```bash
lake build
python3 tests/run_tests.py            # fidelity vs resvg, all corpus files
python3 tests/run_adversarial.py      # must stay 28/28 clean
```
