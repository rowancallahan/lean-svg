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

---

## Report

Measured first, as asked.  The headline is that the diagnosis in step 2 does
not survive measurement: **atomic reference counting is not why the parallel
path scales badly, and path geometry was not where the time went.**  Half of
every render was being spent allocating GMP bignums *per pixel*, because
`Nat`'s left shift is the one bitwise operation Lean's runtime has no scalar
fast path for.  Fixing that, plus the same class of problem in `Mat.apply`, is
worth **1.9-2.3x single-threaded** and the same again in absolute terms at
every thread count.

All numbers below are from this machine — 4-core x86_64 Linux, Lean 4.34.0,
`--width 2000`, `LEAN_NUM_THREADS` matched to `--threads`.  It is not the
8-core arm64 of the table at the top of this file, so the baselines were
re-taken here rather than trusted.

### Step 1 — what is actually happening

**Baseline, main's binary** (median of 5; resvg 0.48.1 for scale):

| image | 1 | 2 | 4 | 8 | resvg |
|---|---|---|---|---|---|
| confetti | 1598 ms | 884 ms | 536 ms | 517 ms | 109 ms |
| icons | 319 ms | 160 ms | 112 ms | 119 ms | 49 ms |
| stress | 3602 ms | 1927 ms | 1046 ms | 1031 ms | 408 ms |

The **2-thread pathology does not reproduce here**: two threads are 1.81x on
confetti, not slower than one.  Four cores buy 2.9-3.4x, which is the same
sublinear shape the task describes.

**The reference-counting hypothesis is refuted three ways.**

1. *Total CPU time does not grow with the number of tasks* (`getrusage` on the
   child): confetti 1561 ms of CPU serial → 1453 ms at 4 threads; stress
   3539 → 3680 (+4%); icons 192 → 256 (+33%, on a 190 ms render dominated by
   per-band fixed cost).  Atomic incref/decref on a shared `Doc` would show up
   as *extra work*, and there is none.
2. *Multi-threaded marking on its own costs nothing.*  With
   `LEAN_NUM_THREADS=1`, `--threads 4` and `--threads 8` still spawn the tasks
   — so `lean_mark_mt` still marks the shared `Doc` and every later refcount
   operation on it is atomic — but run one after another.  Against the serial
   path: confetti 1568 / 1563 / 1546 ms, icons 247 / 250 / 263 ms, stress
   3604 / 3688 / 3661 ms for 0 / 4 / 8 bands.  Within 2%.
3. *Processes are not faster than tasks here.*  Four concurrent processes, each
   rendering one band with its own heap, against one process with four tasks:
   confetti 605 vs **532** ms, icons 120 vs **119** ms, stress **1009** vs
   1080 ms.  T14's 730-vs-980 ms gap does not reproduce.

**Where the time really went.**  callgrind on `16_stress_2000` at `--width
400`: 4.01e9 instructions, ~30% of them inside `malloc`/`free`/`mi_free` and
~16% inside GMP (`__gmpz_mul_2exp`, `__gmpz_add`, `__gmpz_realloc`,
`lean_nat_shiftl`).  The caller tree puts the allocations under
`Canvas.fillMask`/`fillMaskShader` — i.e. per *pixel*.  The cause is one line:

```lean
@[inline] def pack (r g b a : Nat) : Nat := (r <<< 24) ||| (g <<< 16) ||| (b <<< 8) ||| a
```

`lean.h` inlines `lean_nat_shiftr`, `lean_nat_land` and `lean_nat_lor` with a
scalar fast path; `lean_nat_shiftl` is an out-of-line export that goes through
`mpz` and allocates.  Every pixel written to a canvas allocated and freed three
bignums.  (`Canvas.F32.pow2Tab` already documents exactly this for the float
path — `pack` was missed.)

The second offender is `Mat.apply` at **21.6%** of instructions: `m.a * p.x` is
a 16.16 coefficient times an `Fx`, about 2^58, while Lean's unboxed `Int` stops
at `Int32` (`LEAN_MAX_SMALL_INT`), so every transformed point allocated an
`mpz` too.  That is `tasks/README.md` invariant 4, in the one place it matters
most.

**Geometry is not the bottleneck at these sizes.**  Fitting `t = a + b·w²` to
stress (192 / 411 / 1105 / 1570 ms at 400 / 800 / 1600 / 2000 px) gives a
size-independent part of ~135 ms — parse, interpret, culling, flattening,
transforming, edge setup — against ~1435 ms of per-pixel work at 2000 px, so
**~9%**.  confetti's times scale as `w²` to within a percent: essentially
100% per-pixel.  Flattening `Array PathCmd` into flat coordinate arrays, as
step 2 proposes, could not have bought more than a few percent here; the
boxing that mattered was per pixel, not per path element.

**What does limit the scaling**, measured as single-tile renders of each band:

| file | band 0 | band 1 | band 2 | band 3 | slowest / mean |
|---|---|---|---|---|---|
| confetti (k=4) | 325 ms | 351 ms | 354 ms | 467 ms | 1.25 |
| stress (k=4) | 916 ms | 703 ms | 653 ms | 657 ms | 1.25 |

Equal-height rows are not equal work, and the wall clock is the slowest band,
which caps a 4-thread render at ~3.2x however good the runtime is.  Two other
candidates were ruled out: `Png.encode` is not a serial tail (it is stored-mode
deflate — 0 ms, the PNG is the size of the raw pixels), and bands do not
duplicate the *paint* work (the four band tiles sum to within 3% of the full
serial render).  What bands *do* duplicate is the culling pass: an
off-document tile, which parses, interprets and culls every shape but paints
nothing, costs 42 ms for stress (24 ms of it parse+interpret), so ~13 ms per
band for a 2 001-shape document and ~1 ms for confetti.  That is what makes
over-decomposition expensive beyond a point.

### Step 2 — what changed

Four changes, each measured on its own.

1. **`LeanSvg/Canvas.lean` — `pack` multiplies instead of shifting.**  Same
   `Nat` (`n <<< k = n * 2^k`), scalar machine code instead of an `mpz` round
   trip.  Single-threaded at 2000 px: confetti 1570 → 871 ms, stress
   3640 → 1648 ms, icons 239 → 214 ms.  Instruction count on the stress
   profile 4.01e9 → 2.67e9.
2. **`LeanSvg/Geom.lean` — `Mat.apply` does its products in `Int64`.**
   Exact, not approximate: with `|x|, |y| ≤ Fx.maxVal` (2^30) and
   `|a| … |d| ≤ Mat.linMax` (2^28) the products are at most 2^58 and the sum
   2^59, and `>>> 16` on `Int64` *is* `Int.ediv · 65536`.  A guard (six scalar
   comparisons, `Fx.inRange` / `Mat.linInRange`) falls back to the unbounded
   `Int` path for anything out of range, so nothing can wrap.  A microbenchmark
   of the formula alone: 2213 → 490 ms for 3M points.  On renders: stress
   1648 → 1519 ms at 2000 px, and 150 → 107 ms at 200 px, where geometry is
   most of the work.
3. **`LeanSvg/Raster.lean`, `LeanSvg/Render.lean` — hairline strokes are now
   tile-invariant.**  Found by the thread sweep: on `main`, `21_hairlines.svg`
   at `--width 800` renders *differently* at `--threads 3`, `4` and `8` than
   serially, and a `--viewport 0 532 800 268` tile differs from the same crop
   of the full render.  This is a pre-existing bug — my binary reproduced main's
   hashes exactly at every thread count before the fix — and it contradicts the
   guarantee `--threads` is documented to keep.  Two causes, both the same
   shape: `toFDot6` truncates *toward zero*, which rounds the other way for a
   coordinate that is negative in the tile and positive in the image; and
   `do_anti_hairline`'s "pin a sample above the image to row 0" clamp was being
   applied at the *tile's* top row, and written back into the running `fy`, so
   one segment entering a band from above was displaced for its whole length.
   Both now work in whole-image coordinates, which `Raster.hairline` takes as
   `vx`/`vy` exactly as `Grad.build` does; with `vx = vy = 0` — every ordinary
   render — the arithmetic is unchanged, which is why main's output is
   preserved byte for byte.  A sweep of 324 tiles (7 horizontal splits, 4
   vertical, 1 interior window, over all 27 files): **main 320/324, this branch
   324/324**.
4. **`LeanSvg/Render.lean` — `bandsPerThread = 4`.**  With bands no longer
   having to match threads one-to-one, the task pool can even out the uneven
   bands.  Measured at 4 workers, `--width 2000`, median of 15 interleaved
   runs:

   | file | k = threads | 2× | 3× | 4× | 6× |
   |---|---|---|---|---|---|
   | confetti | 288 ms | 331 ms | 291 ms | **259 ms** | 266 ms |
   | stress | 566 ms | 486 ms | **480 ms** | 489 ms | 519 ms |
   | 24_gradients | 302 ms | 241 ms | **218 ms** | 220 ms | 224 ms |
   | 26_layers | 475 ms | 448 ms | 445 ms | 411 ms | **362 ms** |
   | icons | 102 ms | 99 ms | 93 ms | **86 ms** | 87 ms |

   Four is where better balance stops paying for the per-band culling cost.
   The 32-row floor and the "serial unless ≥ 2 threads and ≥ 2·threads rows"
   guard are unchanged, and `0 < bandCount t h` still holds (checked).

`Main.lean` and the `Options.threads` doc comment were updated: `--threads N`
is N *threads*, and the bands are an implementation detail of how they are fed.

### Re-measured table (median of 7)

| image | thr | main | this branch | speedup |
|---|---|---|---|---|
| confetti | 1 | 1609 ms | **865 ms** | 1.86x |
| confetti | 2 | 902 ms | **436 ms** | 2.07x |
| confetti | 4 | 534 ms | **262 ms** | 2.04x |
| confetti | 8 | 539 ms | **292 ms** | 1.84x |
| icons | 1 | 256 ms | **226 ms** | 1.14x |
| icons | 2 | 163 ms | **141 ms** | 1.15x |
| icons | 4 | 117 ms | **94 ms** | 1.25x |
| icons | 8 | 130 ms | **104 ms** | 1.25x |
| stress | 1 | 3514 ms | **1549 ms** | 2.27x |
| stress | 2 | 1978 ms | **860 ms** | 2.30x |
| stress | 4 | 1083 ms | **495 ms** | 2.19x |
| stress | 8 | 1097 ms | **530 ms** | 2.07x |

(8 threads is oversubscribed on this 4-core box, so those rows say nothing
about 8-core scaling.)  Parallel speedup on 4 cores is now 3.30x for confetti
(was 3.01x) and 3.13x for stress (was 3.24x — the same wall-clock balance
problem over a total that is 2.3x smaller, so the per-band fixed cost is a
larger share of it).  The gap to resvg, single-threaded, narrows from 8.6x to
3.8x on stress and from 14.7x to 7.9x on confetti.

The 2-thread pathology cannot be confirmed or denied from here: it never
appeared on this machine, on main or on this branch.  On a 4P+4E arm64 it is
worth re-testing whether the two bands land on one P and one E core.

### Verification

- `lake build` clean from scratch, no errors, no new warnings.
- `git diff origin/main -- LeanSvg/Effect.lean` is empty.
  `LeanSvg.render : Options → ByteArray → Except String ByteArray` unchanged.
  No `partial`, `unsafe`, `@[extern]`, `panic!`, `!`-indexing or `Float` added;
  every new loop is a `for` over a finite range.
- **Byte-identity to main's binary**: all 27 `tests/svg/*.svg` plus the two
  README images, at natural size, `--width 800`, `--width 400 --background
  #3050ff` and a negative-origin viewport — 116/116 identical (exit code,
  bytes and stderr).
- **Thread agreement**: the same 29 files at `--width 800`, `--threads
  1/2/3/4/8/13` against serial — 174/174 identical.  (On main, 21_hairlines
  fails 4 of those; see change 3.)
- **Tiles**: `tests/run_tiles.py` 27/27; plus the 324-tile sweep above, 324/324.
- `tests/run_tests.py` **23/27**, the same scores as main (the renders are
  byte-identical, so they are the same numbers).
- `tests/run_adversarial.py` **61/61 clean, 0 violations**.
- **Corpora** (`resvg-test-suite`, 1 722 files, direct route): at `--width 200`
  against a same-width baseline from main's binary, `0 files moved by more than
  0.1 points`, 0 newly failing.  Stronger: every one of the 1 722 renders is
  **byte-identical** to main's at `--width 200` and at `--width 800`, and
  identical again at `--threads 4`.

### Not done, with numbers

- **Flattening `Shape`/`PathCmd` into flat scalar arrays** — the change this
  task is named after.  The measurement does not support it at the sizes in the
  table: the whole size-independent part of a stress render is ~9% at 2000 px
  and ~0% for confetti.  It would pay on *small* renders, where that part is
  most of the time — stress at `--width 200` is 150 ms on main and 107 ms here,
  almost all of it geometry — and `Mat.apply`, the hottest single piece of it,
  is already done.  Worth reopening as "make small renders fast", with the
  corpora at 200 px as the benchmark, rather than as a parallelism fix.
- **Per-band culling.**  Each band re-walks every shape's control points
  (~13 ms per band on stress).  Precomputing each shape's device control box
  once per document and shifting it per band would make culling O(1) per shape
  — culling can only ever be conservative, so a superset box cannot change a
  pixel — and would let `bandsPerThread` go higher than 4.
- **The allocator is still ~15% of instructions** at `--width 400`, now inside
  `Raster.rasterize`'s sub-scanline loop rather than in GMP.  It looks like
  Lean's `for` state rather than our data (the loop carries ten mutable
  variables); not investigated further.
- **`LeanSvg/Shader.lean` untouched** (T41 is in flight there).  It is the top
  cost for gradient-heavy files: `fillMaskShader` was 18% of confetti's
  instructions before these changes and is a larger share now.
