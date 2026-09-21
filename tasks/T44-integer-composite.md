# T44 — Integer layer compositing, and a packed gradient ramp  [Opus]

**Rowan has authorised a fidelity trade here** (2026-09-21): small pixel
differences are acceptable if the image still looks the same and the corpora
pass rates hold. This is the only task in the project with that permission.
It does not extend to anything else.

## Measurements (this machine, 8-core arm64, `--width 2000`, 2.6 Mpx, median of 7)

Cost per pixel *above a flat fill of the same rectangle*:

| operation | ours | resvg | ratio |
|---|---|---|---|
| one layer, `normal` blend | **210.0 ns/px** | 3.4 ns/px | 62x |
| one layer, `multiply` | 230.9 ns/px | 3.1 ns/px | 74x |
| gradient fill | 25.1 ns/px | 1.3 ns/px | 19x |

Absolute: a full-canvas `<g opacity="0.6">` takes us 641 ms against resvg's
24 ms. Layers are now the single largest remaining cost in the renderer, about
eight times the cost of a gradient over the same area.

## Why

`Canvas.blendPixel` runs the f32 pipeline per pixel. For `.normal` that is
eight table reads, then four `F32.mul`, four `F32.add`, one `F32.sub` and four
`toU8`, each emulating IEEE binary32 in `Nat` with mantissa alignment and
round-to-nearest-even. Roughly 13 software-float operations per pixel where an
integer source-over needs about eight machine instructions.

T22 chose this deliberately and correctly: resvg composites layers through
tiny-skia's **f32** pipeline, because `Pattern::push_stages` emits `Gather`,
which has no lowp implementation, so `is_lowp_compatible` fails. Matching it
bit-for-bit required emulating f32. That was the right call for fidelity and
it is what we are now trading away, for `normal` only.

## The change

1. **Integer source-over for `mode == .normal`.** The canvas already stores
   premultiplied u8 and `Canvas.blendOver` already implements exactly this.
   Fold the group opacity in with `div255 (c * op8)`, quantising the opacity to
   a u8 once per layer the way `opacityToU8` already does elsewhere, then run
   the existing integer source-over. Keep the `copyOpaque` fast path.
   - Leave every other blend mode on the f32 path. They are rarer, and the
     non-separable modes in particular are not worth the risk.
   - Expect the per-pixel cost to fall from ~210 ns to the 15-30 ns range, so
     roughly a 7-10x improvement on layer-heavy content. **Measure it; do not
     assume it.** If the measured gain is under 3x, stop and report rather
     than accepting pixel changes for little in return.
2. **Pack the gradient ramp into one array.** `Grad.rampAt`'s table path reads
   four separate `Array Nat`. One `Array Nat` of packed RGBA is one read and
   one unpack instead of four bounds-checked reads. This one should be
   **bit-exact** — it changes layout, not arithmetic. Do it only if it measures
   as a win; the gradient is now a much smaller target than layers.

## The fidelity bar

This is what "small differences" means, and it is not negotiable:

- **No corpora directory may lose a single passing file.** Run the full suite
  at `--width 200`, direct route, against a same-width baseline built from
  main's binary. The pass metric is 99% of pixels within 8 levels, and a
  one-level rounding difference must not move it.
- **Maximum per-pixel difference of 2 levels** against main's binary, over all
  27 files in `tests/svg` at natural size and at `--width 800`. Report the
  worst file's max delta and the percentage of pixels that changed.
- **Report the changed-pixel percentage per file.** Rowan's guidance was around
  0.5%; treat a file above 2% as a signal that something is wrong with the
  arithmetic rather than a rounding difference, and investigate before
  proceeding.
- `26_layers.svg` and `07_opacity.svg` are the files that exercise this. Render
  both before and after at 800 px and confirm by eye that they are
  indistinguishable, then report the numbers.
- Threads must stay deterministic: `--threads 1/2/4/8` byte-identical to each
  other on `26_layers` at 800 px. Tiles byte-identical. `run_adversarial.py`
  clean. `LeanSvg/Effect.lean` untouched, `render`'s type unchanged, and the
  usual invariants from `tasks/README.md`.

`tests/run_tests.py` byte-identity against main **will** break for files with
layers, and that is expected and authorised. Every other file should stay
byte-identical; say which ones changed.

## Report

Give the measurement table above re-taken before and after, the changed-pixel
percentages, and the corpora before and after. Commit with author
Rowan Callahan <rowan.l.callahan@gmail.com> and a message ending
`Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`, push, and open a pull
request against main whose description is the report and ends with
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do not merge.

Branch `claude/determined-davinci-ilnjp8`, off `main` at `bda274f`. Both parts
done. The headline is 6.4× on a `normal` layer composite for **one** level of
per-pixel difference on **one** of the 27 files in `tests/svg` — a much smaller
fidelity cost than the task budgeted for, because the arithmetic the task
prescribed turned out not to be the one to use. That is the main finding and
§*The rounding is the whole story* below is why.

Measurements are on this machine (4-core x86-64), not the arm64 box the table
at the top was taken on, so the "before" column is re-taken throughout and the
ratios differ from the ones quoted above.

### Files changed

| file | change |
|---|---|
| `LeanSvg/Canvas.lean` | `opGrid`, `opDen`, `div65025`, `storeQ`, `blendOverScaled`; `compositeLayer` split into `compositeNormal` (new) and `compositeBlend` (the old body, unchanged) |
| `LeanSvg/Render.lean` | `opacityQ`, `Layer.opacityQ`, the two `compositeLayer` call sites |
| `LeanSvg/Shader.lean` | `Rt.rr/rg/rb/ra` → one packed `Rt.ramp`; `withRamp`, `rampAt` |
| `DESIGN.md` | §3.9 gains the integer-`normal` paragraph; the deviations line in §3.3 |

`git diff main -- LeanSvg/Effect.lean` is empty. `render`'s type is unchanged.
`lake build` finishes with no errors and no warnings, `tests/CssTests.lean`
still elaborates. No `partial`, `unsafe`, `@[extern]`, `panic!`, `!`-indexing
or `Float` was added; every new loop is a `for` over a range bounded by the
input or a constant, and every constant on the new path is under `2^32`.

### 1. The measurement table, re-taken

`--width 2000`, 2.6 Mpx, median of 7, cost per pixel above a flat fill of the
same rectangle:

| operation | main | this branch | resvg 0.48.1 | ratio to resvg, before → after |
|---|---|---|---|---|
| one layer, `normal` blend | 356.9 ns/px | **55.7 ns/px** | 6.6 ns/px | 54× → **8.5×** |
| one layer, `multiply` | 363.6 ns/px | 393.5 ns/px | 8.4 ns/px | 43× → 47× |
| gradient fill | 51.2 ns/px | 47.8 ns/px | 26.6 ns/px | 1.9× → 1.8× |

**`normal` is 6.4× faster.** The task's bar was 3×; its hoped-for range was
7–10×, and §*The rounding is the whole story* is where the rest of it went.

Whole renders, interleaved A/B, median of 11 alternating runs (the paired form
is worth using here — see §*On the timing noise*):

| render | main | this branch | |
|---|---|---|---|
| full-canvas `<g opacity="0.6">` @2000 | 1147.8 ms | 374.8 ms | 3.06× |
| `26_layers` @800 | 179.6 ms | 151.9 ms | 1.18× |
| `07_opacity` @800 | 61.1 ms | 49.2 ms | 1.24× |
| `confetti` @800 | 119.1 ms | 100.8 ms | 1.18× |
| `24_gradients` @1600 | 447.2 ms | 447.3 ms | 1.00× |
| full-canvas gradient @2000 | 365.1 ms | 346.3 ms | 1.05× |

The `multiply` row is **unchanged code** — `compositeBlend` is the old function
body, untouched — and its 8% is measurement drift, not a regression; see
§*On the timing noise*.

### 2. The rounding is the whole story

The task specified `div255 (c * op8)` and the existing `blendOver`. Implemented
exactly as written, that is **8.2×** faster and fails the fidelity bar:

| | task's arithmetic | what shipped |
|---|---|---|
| speed, `normal` | 342 → 41.8 ns/px (8.2×) | 357 → 55.7 ns/px (6.4×) |
| premultiplied error vs f32 | up to **2** of 255, on 12–17% of pixels | up to **1**, on 0–0.4% |
| worst PNG delta, `tests/svg` | **30** (`07_opacity`) | **1** |
| `tests/svg` files changed | 4 of 27 | **1** of 27 |
| corpus files changed (1716) | 4, worst delta **255** | **1**, worst delta 20 |

Two independent causes, both fixed:

1. **`div255` is a lowp approximation, and it is biased.** `(v + 255) >>> 8` is
   exact only at multiples of 255; elsewhere it rounds *up*, by up to a whole
   level — `div255 1632 = 7` where `1632/255 = 6.4`. That is correct for
   `fillMask`, which has to reproduce tiny-skia's lowp stages bit for bit, and
   wrong here, where the target is the f32 pipeline's single round-to-nearest.
2. **A `u8` opacity cannot represent the commonest opacities.** `0.5` becomes
   `128/255 = 0.50196`. On a nearly transparent pixel that turns a
   fully-transparent output into an alpha-1 one, and `toRgbaBytes`
   unpremultiplies `c·255/a` — so one level of premultiplied error at alpha 6
   is 30 levels in the PNG, and at alpha 0 it is 255.

What shipped does the composite exactly, in integers, with the group opacity on
`opGrid = 255 · 256` and the tie broken to even as `_mm_cvtps_epi32` does:

    out = round_to_nearest_even ( (255·c·op + d·(255 − sa·op)) / 255 )

`255` in the grid keeps an opacity of 1 exact so the copy path stays a copy;
the `256` is what the `u8` was missing. The numerator stays under `2^33`, and
the division is a shift plus `div65025` (a multiply and a shift, `65025 = 255²`
and `opDen = 256 · 65025`), so no hardware division and nothing near GMP.

Checked exhaustively against a `numpy.float32` model of the f32 pipeline over
all 16.7 M `(channel, source alpha, destination)` triples at fourteen
opacities:

| opacity | task's arithmetic | shipped |
|---|---|---|
| 1.0 | max 1, 33.6% changed | **bit-exact** |
| 0.8 / 0.6 / 0.4 | max 2, 47–53% | **bit-exact** |
| 0.5 | max 1, 39.9% | max 1, 0.37% |
| 0.9 | max 2, 55.6% | max 1, 0.11% |
| 0.25 | max 2, 43.8% | max 1, 0.20% |
| 0.01 | max 2, 50.2% | max 1, 0.03% |

Cost of the accuracy: 41.8 → 55.7 ns/px, i.e. 8.2× became 6.4×. Given the
task's instruction that fidelity outranks the speedup and that 3× is the floor,
that is the right end of the trade.

### 3. Fidelity — the bar, item by item

**Max per-pixel delta ≤ 2 over `tests/svg`, natural size and `--width 800`.**
Met with a level to spare. Exactly one file differs from main's binary at
either size, and every other one is byte-identical:

| file | max delta | changed pixels, natural | changed pixels, @800 |
|---|---|---|---|
| `26_layers` | **1** | 3.505% | 3.532% |
| all 26 others | — | byte-identical | byte-identical |

`07_opacity` and `12_badge` changed under the task's arithmetic (3.24% / 4.72%,
max 30 / 1) and are byte-identical under what shipped. `26_layers` is
wall-to-wall layers, so 3.5% is the fraction of its *layer* pixels that shift by
one level; every changed pixel is delta 1 and, at 800 px, every one of them is
on a fully opaque pixel (alpha 255 for all 29 506 of them). That is a rounding
difference, not an arithmetic fault — which is what the task asked to be
established for anything above 2%.

`26_layers` and `07_opacity` rendered at 800 px before and after are
indistinguishable by eye; `07_opacity` is byte-identical, so it is
indistinguishable by construction.

**No corpora directory may lose a passing file.** Full resvg suite, direct
route, `--width 200`, against a same-width baseline built from main's binary:

| | main | this branch |
|---|---|---|
| rendered | 1715 / 1722 | 1715 / 1722 |
| passing (99% within 8) | **872** | **872** |
| newly failing | — | **0** |
| newly passing | — | 0 |
| files moving > 0.1 points of within-8 | — | **0** |

Not one file moved enough to register. Rendering all 1716 renderable files with
both binaries and diffing the PNGs directly, **1715 are byte-identical**; the
one exception is `painting/mix-blend-mode/opacity-on-group.svg`, a
`<g opacity="0.5">` wrapping a `mix-blend-mode:overlay` rect over a gradient
that fades to fully transparent:

| delta | pixels | alpha there |
|---|---|---|
| 1 | 3 780 | 101–255 |
| 2–8 | 520 | 29–114 |
| 18–20 | 40 | 13–14 |

All of it is the unpremultiply amplifying a one-level premultiplied difference:
at alpha 13, one level is `255/13 ≈ 20`. Its within-8 score is unchanged and it
still passes. Under the task's arithmetic this same file had 20 pixels at delta
**255** (alpha 0 becoming alpha 1) and lost 0.45 points of within-8, which is
what sent me looking for better rounding in the first place.

**Determinism.** `--threads 1/2/4/8` byte-identical on `26_layers`,
`24_gradients`, `07_opacity`, `12_badge` and `27_clip` at 800 px. `run_tiles.py`
27/27: quadrant tiles stitch byte-identically to the full render.
`run_adversarial.py` 61/61 clean, 0 violations.

**`run_tests.py` against resvg** — 23/27, the same four failures as main
(`12_badge`, `14_flower_transforms`, `15_spiral_stroke`, `16_stress_2000`), all
pre-existing and unrelated. Only `26_layers` moves, and only in the *exact*
column:

| file | exact, main | exact, here | within-8 | max d |
|---|---|---|---|---|
| `26_layers` | 99.983% | 96.478% | 99.996% → 99.996% | 9 → 9 |

The within-8 metric and the worst-pixel distance from resvg are both untouched.

### 4. The packed gradient ramp

`Rt`'s four `Array Nat` became one `Array Nat` of `Canvas.pack`ed RGBA:
`rampAt` is one bounds-checked read and three shift-and-masks instead of four
bounds-checked reads, and the table is 0.5 MB instead of 2 MB.

Bit-exact, as the task predicted — it changes layout, not arithmetic — and
confirmed: `24_gradients` and every other gradient file stayed byte-identical
to main through this change, and stayed byte-identical across `--threads`
1/2/4/8 (which matters because the band size decides whether a table is built
at all).

It measures as a win, but a small one, and smaller than the task's table
suggests — because on this machine resvg's own gradient is only 1.9× faster
than ours to begin with, not 19×:

| | main | this branch |
|---|---|---|
| gradient, ns/px above a flat fill | 51.2 | 47.8 |
| full-canvas gradient @2000, interleaved | 365.1 ms | 346.3 ms (0.95×) |
| `24_gradients` @1600, interleaved | 447.2 ms | 447.3 ms (1.00×) |

About 13% off the gradient work itself on a full-canvas gradient, and nothing
measurable on a real file, where the gradient is a small part of the frame.
Kept on the strength of being free and bit-exact rather than on the speed.

### 5. On the timing noise

Two things are worth recording for the next task that measures this codebase.

**Unpaired medians on this machine drift by ±5%.** A `bench.py`-style "median
of 7 for A, then median of 7 for B" put `multiply` at +8% and a *flat fill* —
code this branch does not touch at all — at −6% in the same session.
Interleaving the two binaries run by run (`ab.py`) brings the noise floor to
±1%, verified by A/B-ing main against a byte-identical copy of itself
(0.996, 1.010, 0.994).

**There is a real ~2% binary-layout shift.** Even interleaved, the flat-fill
path — again, zero changed code on it — is consistently 1.5–2.7% slower in the
new binary, and `16_stress_2000` is +0.5%. Adding code to `Canvas.lean` moves
everything after it. So `multiply`'s +8% is that shift plus noise rather than a
regression, and `compositeBlend` is the previous function body either way.

Getting there cost three attempts and one wrong conclusion, which is the part
worth recording. Seeing `multiply` at +3% I assumed a shared-loop cost and
restructured twice to remove it — testing `intPath` before `copyOpaque`, then
splitting the loop outright — and the number did not move (1.029 → 1.053 →
1.044, all inside its own band). Only then did I measure the noise floor and an
unchanged code path, which is what the two paragraphs above are, and which is
what I should have done first. The final split into `compositeNormal` /
`compositeBlend` is kept because it makes the f32 function literally the old
one, not because it was shown to be faster; it was not.

### What was not done

`softLight`, the non-separable modes and the other twelve stay on the f32 path
exactly as they were, as the task requires. The `opGrid` quantisation is the
one remaining source of difference and it is irreducible without carrying the
opacity as a full binary32 again — which is the thing being removed. The
residual after that is f32's own rounding noise: where the exact result sits on
a rounding boundary, we round correctly and tiny-skia rounds whichever way its
accumulated error fell. Those are the 0.37% of pixels at opacity 0.5, and we
are arguably the more correct of the two.
