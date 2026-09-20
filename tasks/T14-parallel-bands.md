# T14 — Parallel band rendering with `Task` (byte-identical, theorems untouched)

## Goal

Speed up large renders (the stress file first) by rendering horizontal
bands in parallel with Lean's pure `Task` API, then concatenating rows. See
`PLAN.md` M6b for the rationale: `Task.spawn`/`Task.get` are pure, so
`render`'s type and `Effect.lean` do not change.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T14` (branch
`t14-parallel`). Files: `MicroSvg/Render.lean` (`Options.threads`, the band
split in `render`), `Main.lean` (`--threads N`). Do not touch `drawShape`
(T12 is editing it) beyond calling it, nor `Geom.lean` (T11), `Raster.lean`,
`Canvas.lean`, `Png.lean`.

## Design (decided)

1. `Options.threads : Nat := 0` (0 or 1 = serial, unchanged code path).
2. In `render`, after `canvasSetup` gives the output `(W, H)` for the user's
   options (including any `--viewport X Y W H`): if `threads ≥ 2` and
   `H ≥ 2·threads`, choose `k = min threads (H / 32)` bands of consecutive
   rows (last band takes the remainder). Band `i` covering rows
   `[y0, y1)` is rendered as the **tile** `viewport := (X, Y + y0, W, y1 − y0)`
   where `(X, Y)` is the user's viewport origin (or `(0, 0)`), via exactly the
   existing path: `canvasSetup` with that viewport, the same culling and
   `drawShape` fold, then `Canvas.toRgbaBytes`. Do not duplicate logic;
   factor the existing "options → RGBA bytes" into a function
   `renderRgba (opts) (doc) : Except String (Nat × Nat × ByteArray)` and call
   it per band.
3. Spawn each band with `Task.spawn (fun _ => renderRgba bandOpts doc)`,
   collect in order with `Task.get`, propagate the first error, concatenate
   the RGBA byte arrays (`ByteArray.append`, or pre-size one buffer with
   `copySlice`), then `Png.encode W H rgba` once.
4. Parsing and interpretation (`Xml.parse`, `Svg.interpret`) run once, before
   the bands; the `Doc` is shared read-only (Lean values are immutable, so
   sharing is safe).
5. Invariants (`tasks/README.md`): no `partial`, no `unsafe`, no `IO`; the
   band loop is a `for` over `k`.

## Verify

- **Byte-identity**: for every corpus file at natural size and `--width 1600`,
  `--threads 4` output sha256-equals `--threads 0` output; also with
  `--viewport 100 100 500 300 --width 1600 --threads 3`. Run
  `tests/run_tiles.py` (unchanged) and `run_tests.py` (unchanged 15/20),
  `run_adversarial.py` clean.
- **Scaling**: `16_stress_2000` and `12_badge` at `--width 1600`, wall-clock
  median of 3, for `--threads 1, 2, 4, 8`. Report speedup and note the
  machine's core count (`sysctl -n hw.ncpu`). If the Lean runtime needs a
  thread-pool setting for tasks to run in parallel in a compiled executable,
  find it (`LEAN_NUM_THREADS`? check `lean.h` / the runtime docs) and report.
- Confirm `git diff main -- MicroSvg/Effect.lean` empty and that
  `#print axioms MicroSvg.Prog.renderProgram_spec` still prints `propext`.

## Done when

Byte-identical at every setting tried, scaling table reported, harnesses
clean. Append `## Report`. Commit on the branch.
