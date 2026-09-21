# T14 — Parallel band rendering with `Task` (byte-identical, theorems untouched)

## Goal

Speed up large renders (the stress file first) by rendering horizontal
bands in parallel with Lean's pure `Task` API, then concatenating rows. See
`PLAN.md` M6b for the rationale: `Task.spawn`/`Task.get` are pure, so
`render`'s type and `Effect.lean` do not change.

Work ONLY in `/Users/rowancallahan/pdf_renderer/.worktrees/T14` (branch
`t14-parallel`). Files: `LeanSvg/Render.lean` (`Options.threads`, the band
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
- Confirm `git diff main -- LeanSvg/Effect.lean` empty and that
  `#print axioms LeanSvg.Prog.renderProgram_spec` still prints `propext`.

## Done when

Byte-identical at every setting tried, scaling table reported, harnesses
clean. Append `## Report`. Commit on the branch.

---

## Report

### What changed

- `LeanSvg/Render.lean`
  - `Options.threads : Nat := 0` (0 or 1 = serial, the reference path).
  - `Render.renderRgba (opts) (doc) : Except String (Nat × Nat × ByteArray)` —
    the old body of `render` between `Svg.interpret` and `Png.encode`, lifted
    verbatim. The only place a `Canvas` is built.
  - `Render.bandCount (threads h) : Nat` — `1` unless `threads ≥ 2` and
    `h ≥ 2·threads`, else `max 1 (min threads (h / 32))`.
  - `Render.renderBands (opts) (doc) (w h k)` — band `i` is the tile
    `viewport := (vx, vy + y0, w, y1 - y0)`, spawned with `Task.spawn`,
    collected in order with `Task.get`, RGBA bytes appended into one
    `ByteArray.emptyWithCapacity (w*h*4)`. First error in band order wins.
  - `render` keeps its type and its size checks; it now picks the serial or
    the banded path and calls `Png.encode w h rgba` once.
- `Main.lean`: `--threads N` and the usage text.

Nothing else. `LeanSvg/Effect.lean`, `Geom.lean`, `Raster.lean`, `Canvas.lean`,
`Png.lean` and `drawShape` untouched. No `partial`, `unsafe`, `@[extern]`,
`panic!`, `!`-indexing, `Float` or `IO` added; the band loop is a `for` over
`[0:k]`. `lake build` clean, no new warnings.

### Byte-identity — 1 920 renders, all identical

| sweep | renders |
|---|---|
| 20 corpus files × {natural, `--width 800`, `--width 1600`, `--viewport 100 100 500 300 --width 1600`, `--width 800 --background #3050ff`, `--zoom 2.5`} × `--threads {2,3,4,8,13}` vs `--threads 0` | 600/600 |
| 20 corpus files × 6 off-document / odd-geometry viewports × `--threads {0,1,2,3,4,5,7,8,16,64,1000}` all equal | 1 320/1 320 |

The second sweep is the one that matters for `clipMask`: negative viewport
origins (`-20 -20 400 400`, `-33 -77 640 480 --background #20c08040`), a tile
hanging off the right/bottom, a fully off-document tile, a prime-sized window
(`7 13 501 397`) where `h` is not divisible by `k`, and a 64×900 tall strip.
Error paths agree too (`billion_laughs.svg`: same exit code and same message at
`--threads 0` and `4`).

Harnesses, all unchanged and run once:

- `tests/run_tests.py` — **15/20**, byte-for-byte the same scores as before.
- `tests/run_adversarial.py` — **37/37 clean, 0 violations**.
- `tests/run_tiles.py` — **20/20 quadrant tiles stitch exactly**, off-doc clear,
  partial exact.

### Scaling — Apple M3, `sysctl -n hw.ncpu` = 8 (4 P + 4 E), `--width 1600`, median of 3

Both files render 1600×1600, so `k = threads` for every row here.

| file | threads | default pool | speedup | `LEAN_NUM_THREADS=threads` | speedup |
|---|---|---|---|---|---|
| `12_badge` | 1 | 338 ms | 1.00× | 345 ms | 1.00× |
| `12_badge` | 2 | 201 ms | 1.68× | 202 ms | 1.70× |
| `12_badge` | 4 | 169 ms | 2.00× | 176 ms | 1.96× |
| `12_badge` | 8 | 149 ms | 2.27× | 146 ms | 2.36× |
| `16_stress_2000` | 1 | 2 505 ms | 1.00× | 2 525 ms | 1.00× |
| `16_stress_2000` | 2 | 1 562 ms | 1.60× | 1 437 ms | 1.76× |
| `16_stress_2000` | 4 | 980 ms | 2.56× | 991 ms | 2.55× |
| `16_stress_2000` | 8 | 1 021 ms | 2.45× | 1 065 ms | 2.37× |

8 threads is never better than 4 by much and is worse on the stress file:
only 4 of the 8 cores are performance cores, and equal-row bands make the four
E-core bands the stragglers.

Where the remaining time goes, measured as single tiles (`--viewport 0 y 1600 400`,
median of 3):

| file | band 0 | band 1 | band 2 | band 3 |
|---|---|---|---|---|
| `12_badge` | 42 ms | 154 ms | 152 ms | 46 ms |
| `16_stress_2000` | 707 ms | 670 ms | 626 ms | 629 ms |

`12_badge` is load-imbalanced by construction — the emblem is in the middle two
bands — so its 4-thread wall (169 ms) is already within 10 % of its slowest band
(154 ms). Row bands cannot do better on that file; the fix would be a work queue
of smaller bands, not more threads.

The serial tail is small: an empty 1600×1600 canvas (alloc + `toRgbaBytes` +
`Png.encode`, measured with a fully off-document viewport) is **30 ms**, ~1 % of
the stress render. Fixed cost (process start + `Xml.parse` + `Svg.interpret`) is
20 ms for `16_stress_2000`, under 5 ms for `12_badge`.

### Lean runtime thread pool

`lake`-built executables get, in the generated `Main.c`, a bare
`lean_init_task_manager()` before `lean_run_main`. There is **no `-T` /
`--threads` runtime flag** for a compiled Lean executable — that is `lean`
the compiler's own option, not the runtime's. The knob is the environment
variable **`LEAN_NUM_THREADS`** (the string is in `libleanrt.a`;
`lean_init_task_manager_using(unsigned num_workers)` is the C entry point it
feeds). It works, and it is what proves the tasks really are parallel:

```
16_stress_2000 --width 1600 --threads 8
  LEAN_NUM_THREADS=1   real 2.50 s   user 2.56 s
  LEAN_NUM_THREADS=2   real 1.47 s   user 2.82 s
  LEAN_NUM_THREADS=4   real 1.08 s   user 3.47 s
  LEAN_NUM_THREADS=8   real 1.17 s   user 6.84 s
```

Unset, the pool defaults to `hardware_concurrency` (8 here). With
`--threads 8` and an unset pool, `user 6.98 s` against `real 1.02 s` — 6.8
cores' worth of CPU — so the bands genuinely run concurrently.

### Finding: shared-heap cost, worth a follow-up (not fixed here)

Running the same four bands as four *concurrent processes* (separate heaps,
no shared reference counts) beats four `Task`s in one process:

| k | 4 concurrent processes | in-process `Task`s |
|---|---|---|
| 4 | 730 ms (3.37×) | 980 ms (2.56×) |
| 8 | 557 ms (4.42×) | 1 021 ms (2.45×) |

The likely cause is Lean's multi-threaded reference counting: `lean_task_spawn`
calls `lean_mark_mt` on everything reachable from the closure, so the shared
`Doc` — read in the hot culling and flattening loops by every band — switches
to *atomic* incref/decref on cache lines all bands touch. That is a M6
performance item (give each band its own `Doc`? spawn fewer, coarser tasks?),
not a T14 one; the bytes are correct either way.

### Theorems, type, `Effect.lean`

```
$ git diff main -- LeanSvg/Effect.lean | wc -c
0

$ lake env lean check.lean
LeanSvg.render : LeanSvg.Options → ByteArray → Except String ByteArray
'LeanSvg.Prog.renderProgram_spec' depends on axioms: [propext]
'LeanSvg.Prog.runFS_frame' depends on axioms: [propext]
'LeanSvg.Prog.runFS_input_only' depends on axioms: [propext]
'LeanSvg.Prog.renderProgram_error_no_write' depends on axioms: [propext]
'LeanSvg.Prog.renderProgram_ok_output' depends on axioms: [propext]
'LeanSvg.Prog.renderProgram_ok_frame' depends on axioms: [propext]
```

The scratch file also checks, and Lean accepts, `example (f : Unit → Nat) :
Task.get (Task.spawn f) = f () := rfl` — the purity the whole design rests on —
and `0 < Render.bandCount t h`.

### Not done

- `SESSION_SUMMARY.md` was left alone: it is maintained on `main` after each
  merge, and T11/T12 are live in sibling worktrees.
- No theorem was added for band-identity (`renderPar = render`). PLAN M6b
  allows leaving it as a tested claim; it is tested by the 1 920 renders above
  and by `run_tiles.py`, which is the same argument.
