# T42 — Parallel speedup is 2.2–2.8x on 8 cores: find out why, then fix it  [Opus]

## Measurements to start from

`--width 2000`, median of five runs, 8-core arm64, `--threads N` with
`LEAN_NUM_THREADS` matched:

| image | 1 | 2 | 4 | 8 | resvg (single-threaded) |
|---|---|---|---|---|---|
| confetti | 1450 ms | **1778 ms** | 718 ms | 636 ms | 52 ms |
| icons | 168 ms | 115 ms | 87 ms | 84 ms | 28 ms |
| stress | 3712 ms | 2501 ms | 1340 ms | 1346 ms | 266 ms |

Two separate problems:

1. **Sublinear scaling.** 8 cores buy 2.2–2.8x. Nothing above 4 threads helps.
2. **Two threads are slower than one on `confetti`** (1778 vs 1450 ms), while
   three or more are faster. `icons` and `stress` do not show this.

`tasks/T14-parallel-bands.md` reported that four *processes* beat four tasks
and guessed atomic reference counting on the shared `Doc`. That guess has
never been verified. **Do not assume it.**

Note on scope: processes are not an option. `Task.spawn`/`Task.get` are pure,
so today's parallelism lives inside `render`, which is a pure function, and
`Op` still has exactly two constructors. Spawning processes would need new
effect operations and would destroy the project's strongest guarantee. Any fix
here stays inside the pure renderer.

## Step 1 — measure before changing anything

Find where the time actually goes. Suggestions, use what works:

- Vary the work per band: does the pathology follow band *count* or band
  *height*? Render `confetti` with `--threads 2` at several canvas sizes.
- Does `confetti`'s 2-thread case duplicate work? It has two gradients and two
  layer-forming groups. Instrument or reason about how much of `renderRgba`
  is per-band fixed cost (layer allocation, gradient setup, shape culling)
  rather than per-pixel. A band that intersects a layer may rebuild it.
- Compare against a synthetic file with many flat shapes and no gradients or
  layers, to separate "parallelism is broken" from "this content is expensive".
- If reference counting is the suspect, test it: a run where each task is
  handed a freshly built copy of the shapes it needs should show a different
  curve from one sharing a single `Doc`.

**Write down what you measured before proposing a fix.** A wrong diagnosis
here is expensive, and the last one went unverified for a day.

## Step 2 — the likely fix, if step 1 supports it

Flatten the hot data into unboxed arrays. `Svg.Shape` is currently an
`Array PathCmd` plus a `Style`, and `PathCmd` holds `Pt` structures of `Fx`
(`Int`). Every element touched during rasterisation is a heap object with a
reference count, and once a `Task` shares them those counts become atomic.

An `Array Nat` of scalars carries no per-element reference count at all.
Storing path geometry as flat coordinate arrays plus a small opcode array,
with each shape holding offsets into them, would remove that traffic
entirely, and should help single-threaded speed through cache locality too.

`tasks/README.md` invariant 4 already says hot loops belong in `Nat`, since
Lean's unboxed `Int` is 31-bit.

Do this incrementally. A partial change that is measured and correct beats a
full rewrite that is neither.

## Verify

- `lake build` clean; `git diff origin/main -- LeanSvg/Effect.lean` empty;
  `render`'s type unchanged; no `partial`, `unsafe`, `Float`, `!`-indexing.
- **Output must not change.** All 27 files in `tests/run_tests.py`
  byte-identical to main's binary. `run_tiles.py` byte-identical.
  `--threads 1/2/4/8` byte-identical to each other on `24_gradients`,
  `26_layers` and `16_stress_2000` at 800 px. `run_adversarial.py` clean.
- Corpora at `--width 200`, direct route, against a same-width baseline built
  from main's binary (never compare across widths): no directory below main.
- **Re-measure the table above** and report it before and after, including
  whether the 2-thread pathology is gone.

Commit with author Rowan Callahan <rowan.l.callahan@gmail.com> and a message
ending `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`, push, and open
a pull request against main whose description is the report and ends with
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do not merge.

Note: T41 (gradient ramp) is in flight and touches `LeanSvg/Shader.lean`.
Avoid that file where you can, and rebase onto main before opening the PR.
